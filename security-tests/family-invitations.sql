-- DRAFT ONLY: no deployment until identity recovery and security tests are complete.
begin;
alter table babyfeeding_private.members add column if not exists caregiver_role text check (caregiver_role in ('father','mother'));
create unique index if not exists babyfeeding_family_role on babyfeeding_private.members(family_id,caregiver_role) where caregiver_role is not null;
create table if not exists babyfeeding_private.invitation_secret(id boolean primary key default true check(id),secret bytea not null);
insert into babyfeeding_private.invitation_secret(id,secret) values(true,extensions.gen_random_bytes(32)) on conflict(id) do nothing;
create table if not exists babyfeeding_private.invitations(
  id uuid primary key default gen_random_uuid(), family_id uuid not null,
  digest bytea not null unique, creator_role text not null check(creator_role in ('father','mother')),
  expires_at timestamptz not null, consumed_at timestamptz
);
create table if not exists babyfeeding_private.invitation_limits(
  operation text primary key, window_start timestamptz not null, attempts integer not null
);
alter table babyfeeding_private.invitation_secret enable row level security;
alter table babyfeeding_private.invitations enable row level security;
alter table babyfeeding_private.invitation_limits enable row level security;
revoke all on babyfeeding_private.invitation_secret,babyfeeding_private.invitations,babyfeeding_private.invitation_limits from public,anon,authenticated;

create or replace function babyfeeding_private.limit_invitation(action_name text,max_attempts integer)
returns boolean language plpgsql security definer set search_path='' as $$
declare row_value babyfeeding_private.invitation_limits%rowtype; moment timestamptz:=clock_timestamp();
begin
  insert into babyfeeding_private.invitation_limits(operation,window_start,attempts) values(action_name,moment,0) on conflict(operation) do nothing;
  select * into row_value from babyfeeding_private.invitation_limits where operation=action_name for update;
  if row_value.window_start < moment-interval '10 minutes' then
    update babyfeeding_private.invitation_limits set window_start=moment,attempts=1 where operation=action_name;
    return true;
  end if;
  if row_value.attempts>=max_attempts then return false; end if;
  update babyfeeding_private.invitation_limits set attempts=attempts+1 where operation=action_name;
  return true;
end $$;
revoke all on function babyfeeding_private.limit_invitation(text,integer) from public,anon,authenticated;

create or replace function babyfeeding_private.issue_invite(fid uuid,creator text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare secret_value bytea; raw bytea; candidate bigint; code text; hashed bytea; until_time timestamptz:=clock_timestamp()+interval '10 minutes';
begin
  select secret into secret_value from babyfeeding_private.invitation_secret where id=true;
  update babyfeeding_private.invitations set expires_at=clock_timestamp() where family_id=fid and consumed_at is null and expires_at>clock_timestamp();
  delete from babyfeeding_private.invitations where expires_at < clock_timestamp() - interval '1 day';
  loop
    raw:=extensions.gen_random_bytes(4);
    candidate:=(get_byte(raw,0)::bigint*16777216)+(get_byte(raw,1)::bigint*65536)+(get_byte(raw,2)::bigint*256)+get_byte(raw,3);
    if candidate>=4294000000 then continue; end if;
    code:=lpad((candidate%1000000)::text,6,'0');
    hashed:=extensions.hmac(convert_to(code,'UTF8'),secret_value,'sha256');
    insert into babyfeeding_private.invitations(family_id,digest,creator_role,expires_at) values(fid,hashed,creator,until_time) on conflict(digest) do nothing;
    if found then exit; end if;
  end loop;
  return jsonb_build_object('ok',true,'code',code,'expires_at',until_time);
end $$;
revoke all on function babyfeeding_private.issue_invite(uuid,text) from public,anon,authenticated;

create or replace function babyfeeding_private.family_create(p_role text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare fid uuid:=gen_random_uuid();
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode='42501'; end if;
  if p_role not in ('father','mother') or p_role is null then return jsonb_build_object('ok',false,'reason','invalid_role'); end if;
  if not babyfeeding_private.limit_invitation('create',12) then return jsonb_build_object('ok',false,'reason','rate_limited'); end if;
  if exists(select 1 from babyfeeding_private.members where user_id=auth.uid()) then return jsonb_build_object('ok',false,'reason','already_member'); end if;
  insert into babyfeeding_private.members(user_id,family_id,caregiver_role) values(auth.uid(),fid,p_role);
  return babyfeeding_private.issue_invite(fid,p_role);
end $$;
create or replace function babyfeeding_private.family_new_invite()
returns jsonb language plpgsql security definer set search_path='' as $$
declare m babyfeeding_private.members%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode='42501'; end if;
  select * into m from babyfeeding_private.members where user_id=auth.uid();
  if not found or m.caregiver_role is null then return jsonb_build_object('ok',false,'reason','not_member'); end if;
  if not babyfeeding_private.limit_invitation('issue',12) then return jsonb_build_object('ok',false,'reason','rate_limited'); end if;
  return babyfeeding_private.issue_invite(m.family_id,m.caregiver_role);
end $$;
create or replace function babyfeeding_private.family_join(p_role text,p_code text,p_expected_family uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare secret_value bytea; invitation babyfeeding_private.invitations%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode='42501'; end if;
  if not babyfeeding_private.limit_invitation('join',20) then return jsonb_build_object('ok',false,'reason','rate_limited'); end if;
  if p_role is null or p_role not in ('father','mother') or p_code is null or p_code !~ '^[0-9]{6}$' then return jsonb_build_object('ok',false,'reason','invalid'); end if;
  if exists(select 1 from babyfeeding_private.members where user_id=auth.uid()) then return jsonb_build_object('ok',false,'reason','already_member'); end if;
  select secret into secret_value from babyfeeding_private.invitation_secret where id=true;
  select * into invitation from babyfeeding_private.invitations where digest=extensions.hmac(convert_to(p_code,'UTF8'),secret_value,'sha256') and consumed_at is null and expires_at>clock_timestamp() for update;
  if not found then return jsonb_build_object('ok',false,'reason','invalid'); end if;
  if p_expected_family is not null and invitation.family_id<>p_expected_family then return jsonb_build_object('ok',false,'reason','wrong_family'); end if;
  if p_role=invitation.creator_role then return jsonb_build_object('ok',false,'reason','role_unavailable'); end if;
  -- Joining the opposite role replaces a previous device, only after an existing member issues a code.
  delete from babyfeeding_private.members where family_id=invitation.family_id and caregiver_role=p_role;
  insert into babyfeeding_private.members(user_id,family_id,caregiver_role) values(auth.uid(),invitation.family_id,p_role);
  update babyfeeding_private.invitations set consumed_at=clock_timestamp() where id=invitation.id;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function babyfeeding_private.family_create(text),babyfeeding_private.family_join(text,text,uuid),babyfeeding_private.family_new_invite() from public,anon;
grant execute on function babyfeeding_private.family_create(text),babyfeeding_private.family_join(text,text,uuid),babyfeeding_private.family_new_invite() to authenticated;
create or replace function public.babyfeeding_family_create(p_role text) returns jsonb language sql security invoker set search_path='' as $$ select babyfeeding_private.family_create(p_role) $$;
create or replace function public.babyfeeding_family_join(p_role text,p_code text,p_expected_family uuid default null) returns jsonb language sql security invoker set search_path='' as $$ select babyfeeding_private.family_join(p_role,p_code,p_expected_family) $$;
create or replace function public.babyfeeding_family_new_invite() returns jsonb language sql security invoker set search_path='' as $$ select babyfeeding_private.family_new_invite() $$;
revoke all on function public.babyfeeding_family_create(text),public.babyfeeding_family_join(text,text,uuid),public.babyfeeding_family_new_invite() from public,anon;
grant execute on function public.babyfeeding_family_create(text),public.babyfeeding_family_join(text,text,uuid),public.babyfeeding_family_new_invite() to authenticated;
commit;

