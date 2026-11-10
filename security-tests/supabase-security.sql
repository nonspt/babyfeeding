-- For a disposable test database only. Requires both draft migrations to be installed.
-- The entire test rolls back; never use it on a production database with user data.
begin;
create temporary table test_users (name text primary key, id uuid not null) on commit drop;
insert into test_users values ('father',gen_random_uuid()),('mother',gen_random_uuid()),('outsider',gen_random_uuid()),('replacement',gen_random_uuid());
insert into auth.users(id,aud,role) select id,'authenticated','authenticated' from test_users;
create temporary table test_values (name text primary key,value jsonb) on commit drop;
select set_config('request.jwt.claim.sub',(select id::text from test_users where name='father'),true);
insert into test_values values ('created',public.babyfeeding_family_create('father'));
do $$ begin
  if not ((select value->>'ok' from test_values where name='created')::boolean) then raise exception 'create failed'; end if;
  if not ((select value->>'code' from test_values where name='created') ~ '^[0-9]{6}$') then raise exception 'bad code'; end if;
  if has_function_privilege('anon','public.babyfeeding_family_join(text,text,uuid)','execute') then raise exception 'anonymous RPC access'; end if;
  if has_table_privilege('authenticated','babyfeeding_private.items','select') then raise exception 'direct table access'; end if;
end $$;
select set_config('request.jwt.claim.sub',(select id::text from test_users where name='mother'),true);
insert into test_values values ('joined',public.babyfeeding_family_join('mother',(select value->>'code' from test_values where name='created'),null));
do $$ begin if not ((select value->>'ok' from test_values where name='joined')::boolean) then raise exception 'join failed'; end if; end $$;
select set_config('request.jwt.claim.sub',(select id::text from test_users where name='outsider'),true);
do $$ declare r jsonb; begin
  r:=public.babyfeeding_family_join('mother',(select value->>'code' from test_values where name='created'),null);
  if r->>'reason'<>'invalid' then raise exception 'code replay accepted'; end if;
  begin perform public.babyfeeding_sync_family(); raise exception 'outsider access granted'; exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub',(select id::text from test_users where name='father'),true);
insert into test_values values ('newcode',public.babyfeeding_family_new_invite());
select set_config('request.jwt.claim.sub',(select id::text from test_users where name='replacement'),true);
insert into test_values values ('replaced',public.babyfeeding_family_join('mother',(select value->>'code' from test_values where name='newcode'),null));
do $$ begin if not ((select value->>'ok' from test_values where name='replaced')::boolean) then raise exception 'replacement failed'; end if; end $$;
select set_config('request.jwt.claim.sub',(select id::text from test_users where name='mother'),true);
do $$ begin begin perform public.babyfeeding_sync_family(); raise exception 'replaced device still has access'; exception when insufficient_privilege then null; end; end $$;
rollback;

