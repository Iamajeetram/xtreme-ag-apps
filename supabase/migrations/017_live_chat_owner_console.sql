-- Xtreme AG Apps: Owner Console + Live Chat
-- Run after the existing service_recommendations migration.
create extension if not exists pgcrypto;

create table if not exists public.owner_credentials (
  id boolean primary key default true check (id),
  username text not null unique,
  password_hash text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.owner_credentials (id, username, password_hash)
values (true, '787886908432', '$2a$12$6br2JkNVUZH/WA8RuiYvwuQylGH65bpQhOLKlu5jwMgj4Y1P9SKyG')
on conflict (id) do update set username=excluded.username, password_hash=excluded.password_hash, updated_at=now();

create table if not exists public.owner_sessions (
  token_hash text primary key,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);
create index if not exists owner_sessions_expires_idx on public.owner_sessions(expires_at);

create or replace function public.owner_login(p_username text, p_password text)
returns table(session_token text, expires_at timestamptz)
language plpgsql security definer set search_path=public, extensions
as $$
declare v_hash text; v_token text; v_exp timestamptz;
begin
  select password_hash into v_hash from public.owner_credentials where username=trim(p_username) and id=true;
  if v_hash is null or crypt(p_password, v_hash) <> v_hash then
    raise exception 'Invalid Owner ID or password';
  end if;
  v_token := encode(gen_random_bytes(32), 'hex');
  v_exp := now() + interval '7 days';
  insert into public.owner_sessions(token_hash, expires_at)
  values (encode(digest(v_token,'sha256'),'hex'), v_exp);
  return query select v_token, v_exp;
end $$;

create or replace function public.owner_logout(p_token text)
returns boolean language plpgsql security definer set search_path=public, extensions
as $$
begin
  update public.owner_sessions set revoked_at=now()
  where token_hash=encode(digest(p_token,'sha256'),'hex') and revoked_at is null;
  return true;
end $$;

create or replace function public.is_owner_session(p_token text)
returns boolean language sql security definer set search_path=public, extensions
as $$
  select exists(select 1 from public.owner_sessions where token_hash=encode(digest(p_token,'sha256'),'hex') and revoked_at is null and expires_at>now());
$$;

-- Existing query table: status and admin-safe RPCs.
alter table public.service_recommendations add column if not exists status text not null default 'new';
alter table public.service_recommendations drop constraint if exists service_recommendations_status_check;
alter table public.service_recommendations add constraint service_recommendations_status_check check (status in ('new','contacted','resolved'));

create or replace function public.owner_list_queries(p_token text)
returns setof public.service_recommendations
language plpgsql security definer set search_path=public
as $$
begin
 if not public.is_owner_session(p_token) then raise exception 'Owner session expired'; end if;
 return query select * from public.service_recommendations order by created_at desc;
end $$;

create or replace function public.owner_update_query_status(p_token text, p_id uuid, p_status text)
returns boolean language plpgsql security definer set search_path=public
as $$
begin
 if not public.is_owner_session(p_token) then raise exception 'Owner session expired'; end if;
 if p_status not in ('new','contacted','resolved') then raise exception 'Invalid status'; end if;
 update public.service_recommendations set status=p_status where id=p_id;
 return found;
end $$;

-- Live chat.
create table if not exists public.chat_conversations (
  id uuid primary key default gen_random_uuid(),
  visitor_name text,
  visitor_mobile text,
  visitor_session text not null unique,
  visitor_user_id uuid references auth.users(id) on delete set null,
  status text not null default 'open' check (status in ('open','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.chat_conversations(id) on delete cascade,
  sender text not null check (sender in ('visitor','owner')),
  message text not null check (length(trim(message)) between 1 and 3000),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists chat_messages_conversation_created_idx on public.chat_messages(conversation_id, created_at);
create index if not exists chat_conversations_updated_idx on public.chat_conversations(updated_at desc);

alter table public.chat_conversations enable row level security;
alter table public.chat_messages enable row level security;

grant select, insert, update on public.chat_conversations to anon, authenticated;
grant select, insert, update on public.chat_messages to anon, authenticated;

drop policy if exists visitor_conversation_access on public.chat_conversations;
create policy visitor_conversation_access on public.chat_conversations for select to authenticated using (visitor_user_id = auth.uid());
drop policy if exists visitor_conversation_insert on public.chat_conversations;
create policy visitor_conversation_insert on public.chat_conversations for insert to authenticated with check (visitor_user_id = auth.uid() and length(visitor_session) between 16 and 100);
drop policy if exists visitor_conversation_update on public.chat_conversations;
create policy visitor_conversation_update on public.chat_conversations for update to authenticated using (visitor_user_id = auth.uid()) with check (visitor_user_id = auth.uid());

drop policy if exists visitor_message_access on public.chat_messages;
create policy visitor_message_access on public.chat_messages for select to authenticated using (exists(select 1 from public.chat_conversations c where c.id=conversation_id and c.visitor_user_id=auth.uid()));
drop policy if exists visitor_message_insert on public.chat_messages;
create policy visitor_message_insert on public.chat_messages for insert to authenticated with check (sender='visitor' and exists(select 1 from public.chat_conversations c where c.id=conversation_id and c.visitor_user_id=auth.uid()));

-- Keep realtime available for chat tables.
alter table public.chat_conversations replica identity full;
alter table public.chat_messages replica identity full;

revoke all on public.owner_credentials from anon, authenticated;
revoke all on public.owner_sessions from anon, authenticated;
grant execute on function public.owner_login(text,text) to anon, authenticated;
grant execute on function public.owner_logout(text) to anon, authenticated;
grant execute on function public.is_owner_session(text) to anon, authenticated;
grant execute on function public.owner_list_queries(text) to anon, authenticated;
grant execute on function public.owner_update_query_status(text,uuid,text) to anon, authenticated;
grant execute on function public.owner_list_chats(text) to anon, authenticated;
grant execute on function public.owner_get_chat(text,uuid) to anon, authenticated;
grant execute on function public.owner_send_chat(text,uuid,text) to anon, authenticated;
grant execute on function public.owner_close_chat(text,uuid) to anon, authenticated;

create or replace function public.chat_touch_conversation()
returns trigger language plpgsql security definer set search_path=public
as $$ begin update public.chat_conversations set updated_at=now() where id=new.conversation_id; return new; end $$;
drop trigger if exists trg_chat_touch_conversation on public.chat_messages;
create trigger trg_chat_touch_conversation after insert on public.chat_messages for each row execute function public.chat_touch_conversation();

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='chat_conversations') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_conversations;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='chat_messages') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;
  END IF;
EXCEPTION WHEN undefined_object THEN NULL; END $$;
