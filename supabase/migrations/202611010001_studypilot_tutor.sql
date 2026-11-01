-- StudyPilot Tutor AI schema. Review before applying to your Supabase project.
create extension if not exists pgcrypto;
create table if not exists public.tutor_conversations (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 title text not null default 'Nouvelle conversation',
 subject text not null default 'Autre',
 education_level text not null default 'Lycée',
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.tutor_messages (
 id uuid primary key default gen_random_uuid(),
 conversation_id uuid not null references public.tutor_conversations(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 role text not null check (role in ('user','assistant')),
 content text not null,
 created_at timestamptz not null default now()
);
create table if not exists public.tutor_attachments (
 id uuid primary key default gen_random_uuid(),
 conversation_id uuid not null references public.tutor_conversations(id) on delete cascade,
 message_id uuid not null references public.tutor_messages(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 storage_path text not null,
 mime_type text not null check (mime_type in ('image/jpeg','image/png','image/webp')),
 file_size integer not null check (file_size between 1 and 5242880),
 created_at timestamptz not null default now()
);
create table if not exists public.tutor_usage (
 user_id uuid not null references auth.users(id) on delete cascade,
 usage_date date not null default (now() at time zone 'utc')::date,
 text_questions integer not null default 0,
 image_questions integer not null default 0,
 updated_at timestamptz not null default now(),
 primary key(user_id,usage_date)
);
create table if not exists public.tutor_feedback (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 message_id uuid not null references public.tutor_messages(id) on delete cascade,
 rating integer not null check (rating between 1 and 5),
 comment text,
 created_at timestamptz not null default now()
);
create index if not exists tutor_conversations_user_updated_idx on public.tutor_conversations(user_id,updated_at desc);
create index if not exists tutor_messages_conversation_created_idx on public.tutor_messages(conversation_id,created_at);
alter table public.tutor_conversations enable row level security;
alter table public.tutor_messages enable row level security;
alter table public.tutor_attachments enable row level security;
alter table public.tutor_usage enable row level security;
alter table public.tutor_feedback enable row level security;
create policy "own conversations select" on public.tutor_conversations for select using (auth.uid()=user_id);
create policy "own conversations insert" on public.tutor_conversations for insert with check (auth.uid()=user_id);
create policy "own conversations update" on public.tutor_conversations for update using (auth.uid()=user_id) with check (auth.uid()=user_id);
create policy "own conversations delete" on public.tutor_conversations for delete using (auth.uid()=user_id);
create policy "own messages select" on public.tutor_messages for select using (auth.uid()=user_id);
create policy "own messages insert" on public.tutor_messages for insert with check (auth.uid()=user_id and exists(select 1 from public.tutor_conversations c where c.id=conversation_id and c.user_id=auth.uid()));
create policy "own messages delete" on public.tutor_messages for delete using (auth.uid()=user_id);
create policy "own attachments select" on public.tutor_attachments for select using (auth.uid()=user_id);
create policy "own attachments insert" on public.tutor_attachments for insert with check (auth.uid()=user_id and exists(select 1 from public.tutor_conversations c where c.id=conversation_id and c.user_id=auth.uid()));
create policy "own attachments delete" on public.tutor_attachments for delete using (auth.uid()=user_id);
create policy "own usage select" on public.tutor_usage for select using (auth.uid()=user_id);
create policy "own feedback select" on public.tutor_feedback for select using (auth.uid()=user_id);
create policy "own feedback insert" on public.tutor_feedback for insert with check (auth.uid()=user_id);
-- Atomic quota consumption; only authenticated callers can consume their own quota.
create or replace function public.consume_tutor_quota(p_is_image boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); d date:=(now() at time zone 'utc')::date; t integer; i integer;
begin
 if uid is null then raise exception 'UNAUTHENTICATED'; end if;
 insert into public.tutor_usage(user_id,usage_date) values(uid,d) on conflict(user_id,usage_date) do nothing;
 if p_is_image then
  update public.tutor_usage set image_questions=image_questions+1,updated_at=now()
  where user_id=uid and usage_date=d and image_questions<2 returning text_questions,image_questions into t,i;
 else
  update public.tutor_usage set text_questions=text_questions+1,updated_at=now()
  where user_id=uid and usage_date=d and text_questions<5 returning text_questions,image_questions into t,i;
 end if;
 if not found then select text_questions,image_questions into t,i from public.tutor_usage where user_id=uid and usage_date=d; return jsonb_build_object('allowed',false,'text_remaining',greatest(0,5-t),'image_remaining',greatest(0,2-i)); end if;
 return jsonb_build_object('allowed',true,'text_remaining',greatest(0,5-t),'image_remaining',greatest(0,2-i));
end; $$;
revoke all on function public.consume_tutor_quota(boolean) from public;
grant execute on function public.consume_tutor_quota(boolean) to authenticated;
-- Private image bucket; user uploads are restricted to their own uid-prefixed folder.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('tutor-attachments','tutor-attachments',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];
create policy "tutor files own select" on storage.objects for select to authenticated using(bucket_id='tutor-attachments' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "tutor files own insert" on storage.objects for insert to authenticated with check(bucket_id='tutor-attachments' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "tutor files own delete" on storage.objects for delete to authenticated using(bucket_id='tutor-attachments' and (storage.foldername(name))[1]=auth.uid()::text);
