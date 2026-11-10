-- REVIEW ONLY: run in a Supabase SQL editor after explicit deployment approval.
-- All cloud tables are kept outside the exposed API schema. No personal data here.
begin;
create schema if not exists babyfeeding_private;
revoke all on schema babyfeeding_private from public, anon, authenticated;
grant usage on schema babyfeeding_private to authenticated;
create table if not exists babyfeeding_private.members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  family_id uuid not null,
  created_at timestamptz not null default now()
);
create table if not exists babyfeeding_private.items (
  family_id uuid not null,
  entity_id text not null check (length(entity_id) between 1 and 80),
  revision bigint not null default 0,
  payload jsonb,
  deleted boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (family_id, entity_id)
);
create table if not exists babyfeeding_private.receipts (
  family_id uuid not null,
  op_id uuid not null,
  entity_id text not null,
  revision bigint not null,
  result jsonb,
  request_hash text not null,
  primary key (family_id, op_id)
);
alter table babyfeeding_private.members enable row level security;
alter table babyfeeding_private.items enable row level security;
alter table babyfeeding_private.receipts enable row level security;
revoke all on all tables in schema babyfeeding_private from public, anon, authenticated;

create or replace function babyfeeding_private.babyfeeding_sync_pull(p_after text default '',p_since timestamptz default null)
returns table(entity_id text,revision bigint,payload jsonb,deleted boolean,updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare fid uuid;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode='42501'; end if;
  select m.family_id into fid from babyfeeding_private.members m where m.user_id=auth.uid();
  if fid is null then raise exception 'not a family member' using errcode='42501'; end if;
  if p_after is null or length(p_after)>80 then raise exception 'invalid cursor' using errcode='22023'; end if;
  return query select i.entity_id,i.revision,i.payload,i.deleted,i.updated_at from babyfeeding_private.items i where i.family_id=fid and i.entity_id>p_after and (p_since is null or i.updated_at>=p_since) order by i.entity_id limit 200;
end $$;

-- Reject malformed client payloads before they can interrupt another member's sync.
create or replace function babyfeeding_private.validate_payload(entity text, value jsonb)
returns void language plpgsql set search_path = '' as $$
begin
  if value is null or jsonb_typeof(value)<>'object' or pg_column_size(value)>16384 then raise exception 'invalid payload' using errcode='22023'; end if;
  if entity='active-nurse' then
    if not ((value->>'side' in ('left','right')) is true) or jsonb_typeof(value->'paused') is distinct from 'boolean'
      or jsonb_typeof(value->'start') is distinct from 'number' or jsonb_typeof(value->'runningSince') is distinct from 'number'
      or jsonb_typeof(value->'leftMs') is distinct from 'number' or jsonb_typeof(value->'rightMs') is distinct from 'number' then raise exception 'invalid timer' using errcode='22023'; end if;
    if (value->>'start')::numeric<=0 or (value->>'runningSince')::numeric<=0 or (value->>'leftMs')::numeric<0 or (value->>'rightMs')::numeric<0 then raise exception 'invalid timer' using errcode='22023'; end if;
  else
    if value->>'id' is distinct from entity or not ((value->>'type' in ('bottle','nurse')) is true)
      or jsonb_typeof(value->'version') is distinct from 'number' or value->>'version' is distinct from '1'
      or jsonb_typeof(value->'at') is distinct from 'number' or jsonb_typeof(value->'createdAt') is distinct from 'number' or jsonb_typeof(value->'updatedAt') is distinct from 'number' then raise exception 'invalid record' using errcode='22023'; end if;
    if (value->>'at')::numeric<=0 or (value->>'createdAt')::numeric<=0 or (value->>'updatedAt')::numeric<=0 then raise exception 'invalid record time' using errcode='22023'; end if;
    if value->>'type'='bottle' then
      if jsonb_typeof(value->'amount') is distinct from 'number' then raise exception 'invalid bottle amount' using errcode='22023'; end if;
      if (value->>'amount')::numeric not between 1 and 2000 then raise exception 'invalid bottle amount' using errcode='22023'; end if;
      if value ? 'milkKind' and not ((value->>'milkKind' in ('母乳','奶粉','混合')) is true) then raise exception 'invalid milk type' using errcode='22023'; end if;
    else
      if jsonb_typeof(value->'duration') is distinct from 'number' or not ((value->>'side' in ('left','right','both')) is true) then raise exception 'invalid nurse record' using errcode='22023'; end if;
      if (value->>'duration')::numeric<0 then raise exception 'invalid nurse duration' using errcode='22023'; end if;
    end if;
  end if;
end $$;
revoke all on function babyfeeding_private.validate_payload(text,jsonb) from public, anon, authenticated;

create or replace function babyfeeding_private.babyfeeding_sync_commit(p_op_id uuid,p_entity_id text,p_expected_revision bigint,p_payload jsonb,p_deleted boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare fid uuid; item babyfeeding_private.items%rowtype; receipt babyfeeding_private.receipts%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode='42501'; end if;
  select m.family_id into fid from babyfeeding_private.members m where m.user_id=auth.uid();
  if fid is null then raise exception 'not a family member' using errcode='42501'; end if;
  if p_op_id is null or p_entity_id is null or length(p_entity_id) not between 1 and 80 or p_expected_revision is null or p_expected_revision<0 or p_deleted is null then raise exception 'invalid request' using errcode='22023'; end if;
  if p_entity_id <> 'active-nurse' and p_entity_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'invalid entity' using errcode='22023'; end if;
  if not p_deleted then perform babyfeeding_private.validate_payload(p_entity_id,p_payload); end if;
  perform pg_advisory_xact_lock(hashtextextended(fid::text || ':' || p_entity_id,0));
  select * into receipt from babyfeeding_private.receipts r where r.family_id=fid and r.op_id=p_op_id;
  if found then
    if receipt.entity_id<>p_entity_id or receipt.request_hash<>md5(jsonb_build_array(p_entity_id,p_expected_revision,p_payload,p_deleted)::text) then raise exception 'operation id reused' using errcode='22023'; end if;
    return jsonb_build_object('ok',true,'revision',receipt.revision,'replayed',true);
  end if;
  select * into item from babyfeeding_private.items i where i.family_id=fid and i.entity_id=p_entity_id for update;
  if coalesce(item.revision,0)<>p_expected_revision then
    return jsonb_build_object('ok',false,'conflict',true,'revision',coalesce(item.revision,0),'payload',item.payload,'deleted',coalesce(item.deleted,false));
  end if;
  insert into babyfeeding_private.items(family_id,entity_id,revision,payload,deleted,updated_at)
    values(fid,p_entity_id,p_expected_revision+1,case when p_deleted then null else p_payload end,p_deleted,now())
    on conflict(family_id,entity_id) do update set revision=excluded.revision,payload=excluded.payload,deleted=excluded.deleted,updated_at=excluded.updated_at;
  insert into babyfeeding_private.receipts(family_id,op_id,entity_id,revision,request_hash) values(fid,p_op_id,p_entity_id,p_expected_revision+1,md5(jsonb_build_array(p_entity_id,p_expected_revision,p_payload,p_deleted)::text));
  return jsonb_build_object('ok',true,'revision',p_expected_revision+1,'replayed',false);
end $$;
revoke all on function babyfeeding_private.babyfeeding_sync_pull(text,timestamptz) from public, anon;
revoke all on function babyfeeding_private.babyfeeding_sync_commit(uuid,text,bigint,jsonb,boolean) from public, anon;
grant execute on function babyfeeding_private.babyfeeding_sync_pull(text,timestamptz) to authenticated;
grant execute on function babyfeeding_private.babyfeeding_sync_commit(uuid,text,bigint,jsonb,boolean) to authenticated;
-- Returns the caller's family identifier; membership is provisioned by the owner.
create or replace function babyfeeding_private.babyfeeding_sync_family()
returns uuid language plpgsql security definer set search_path = '' as $$
declare fid uuid;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode='42501'; end if;
  select m.family_id into fid from babyfeeding_private.members m where m.user_id=auth.uid();
  if fid is null then raise exception 'not a family member' using errcode='42501'; end if;
  return fid;
end $$;
revoke all on function babyfeeding_private.babyfeeding_sync_family() from public, anon;
grant execute on function babyfeeding_private.babyfeeding_sync_family() to authenticated;
-- Finish a shared timer and save its final record as one transaction.
create or replace function babyfeeding_private.babyfeeding_sync_finish(p_op_id uuid,p_record_id text,p_record_revision bigint,p_timer_revision bigint,p_record jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare fid uuid; timer_row babyfeeding_private.items%rowtype; record_row babyfeeding_private.items%rowtype; prior babyfeeding_private.receipts%rowtype; answer jsonb;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode='42501'; end if;
  select m.family_id into fid from babyfeeding_private.members m where m.user_id=auth.uid();
  if fid is null then raise exception 'not a family member' using errcode='42501'; end if;
  if p_op_id is null or p_record_id is null or p_record_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or p_record_revision is null or p_record_revision<0 or p_timer_revision is null or p_timer_revision<0 or p_record is null or jsonb_typeof(p_record)<>'object' or pg_column_size(p_record)>16384 or p_record->>'id' is distinct from p_record_id or p_record->>'type' is distinct from 'nurse' then raise exception 'invalid request' using errcode='22023'; end if;
  perform babyfeeding_private.validate_payload(p_record_id,p_record);
  perform pg_advisory_xact_lock(hashtextextended(fid::text || ':active-nurse',0));
  perform pg_advisory_xact_lock(hashtextextended(fid::text || ':' || p_record_id,0));
  select * into prior from babyfeeding_private.receipts r where r.family_id=fid and r.op_id=p_op_id;
  if found then
    if prior.entity_id<>('finish:'||p_record_id) or prior.result is null or prior.request_hash<>md5(jsonb_build_array(p_record_id,p_record_revision,p_timer_revision,p_record)::text) then raise exception 'operation id reused' using errcode='22023'; end if;
    return prior.result;
  end if;
  select * into timer_row from babyfeeding_private.items i where i.family_id=fid and i.entity_id='active-nurse' for update;
  select * into record_row from babyfeeding_private.items i where i.family_id=fid and i.entity_id=p_record_id for update;
  if coalesce(timer_row.revision,0)<>p_timer_revision or coalesce(timer_row.deleted,true) or timer_row.payload->>'start' is distinct from p_record->>'at' or coalesce(record_row.revision,0)<>p_record_revision then
    return jsonb_build_object('ok',false,'conflict',true,'timer_revision',coalesce(timer_row.revision,0),'timer_payload',timer_row.payload,'timer_deleted',coalesce(timer_row.deleted,false),'record_revision',coalesce(record_row.revision,0),'record_payload',record_row.payload,'record_deleted',coalesce(record_row.deleted,false));
  end if;
  insert into babyfeeding_private.items(family_id,entity_id,revision,payload,deleted,updated_at) values(fid,'active-nurse',p_timer_revision+1,null,true,now()) on conflict(family_id,entity_id) do update set revision=excluded.revision,payload=null,deleted=true,updated_at=excluded.updated_at;
  insert into babyfeeding_private.items(family_id,entity_id,revision,payload,deleted,updated_at) values(fid,p_record_id,p_record_revision+1,p_record,false,now()) on conflict(family_id,entity_id) do update set revision=excluded.revision,payload=excluded.payload,deleted=false,updated_at=excluded.updated_at;
  answer=jsonb_build_object('ok',true,'timer_revision',p_timer_revision+1,'record_revision',p_record_revision+1);
  insert into babyfeeding_private.receipts(family_id,op_id,entity_id,revision,result,request_hash) values(fid,p_op_id,'finish:'||p_record_id,p_timer_revision+1,answer,md5(jsonb_build_array(p_record_id,p_record_revision,p_timer_revision,p_record)::text));
  return answer;
end $$;
revoke all on function babyfeeding_private.babyfeeding_sync_finish(uuid,text,bigint,bigint,jsonb) from public, anon;
grant execute on function babyfeeding_private.babyfeeding_sync_finish(uuid,text,bigint,bigint,jsonb) to authenticated;

-- Public RPC wrappers run as the caller; privileged functions remain in the unexposed schema.
create or replace function public.babyfeeding_sync_pull(p_after text default '',p_since timestamptz default null)
returns table(entity_id text,revision bigint,payload jsonb,deleted boolean,updated_at timestamptz)
language sql security invoker set search_path = '' as $$ select * from babyfeeding_private.babyfeeding_sync_pull(p_after,p_since) $$;
create or replace function public.babyfeeding_sync_commit(p_op_id uuid,p_entity_id text,p_expected_revision bigint,p_payload jsonb,p_deleted boolean)
returns jsonb language sql security invoker set search_path = '' as $$ select babyfeeding_private.babyfeeding_sync_commit(p_op_id,p_entity_id,p_expected_revision,p_payload,p_deleted) $$;
create or replace function public.babyfeeding_sync_family()
returns uuid language sql security invoker set search_path = '' as $$ select babyfeeding_private.babyfeeding_sync_family() $$;
create or replace function public.babyfeeding_sync_finish(p_op_id uuid,p_record_id text,p_record_revision bigint,p_timer_revision bigint,p_record jsonb)
returns jsonb language sql security invoker set search_path = '' as $$ select babyfeeding_private.babyfeeding_sync_finish(p_op_id,p_record_id,p_record_revision,p_timer_revision,p_record) $$;
revoke all on function public.babyfeeding_sync_pull(text,timestamptz) from public, anon;
revoke all on function public.babyfeeding_sync_commit(uuid,text,bigint,jsonb,boolean) from public, anon;
revoke all on function public.babyfeeding_sync_family() from public, anon;
revoke all on function public.babyfeeding_sync_finish(uuid,text,bigint,bigint,jsonb) from public, anon;
grant execute on function public.babyfeeding_sync_pull(text,timestamptz) to authenticated;
grant execute on function public.babyfeeding_sync_commit(uuid,text,bigint,jsonb,boolean) to authenticated;
grant execute on function public.babyfeeding_sync_family() to authenticated;
grant execute on function public.babyfeeding_sync_finish(uuid,text,bigint,bigint,jsonb) to authenticated;

commit;

