-- NBA DICE shared data schema. Run in Supabase SQL Editor.
create extension if not exists pgcrypto;
create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 player_name text not null check (char_length(player_name) between 1 and 24),
 coins bigint not null default 1200 check (coins >= 0),
 played bigint not null default 0, won bigint not null default 0,
 is_host boolean not null default false, created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.game_history (
 id uuid primary key default gen_random_uuid(),
 player_id uuid not null references public.profiles(id) on delete cascade,
 pick_one smallint not null check (pick_one between 1 and 6),
 pick_two smallint not null check (pick_two between 1 and 6),
 dice smallint[] not null check (array_length(dice,1)=6),
 bet bigint not null check (bet > 0), matches smallint not null check (matches between 0 and 6),
 payout bigint not null check (payout >= 0), created_at timestamptz not null default now()
);
create table if not exists public.groups (
 id uuid primary key default gen_random_uuid(), name text not null,
 invite_code text not null unique default upper(substr(encode(gen_random_bytes(8),'hex'),1,8)),
 created_by uuid references public.profiles(id) on delete set null,
 status text not null default 'open' check (status in ('open','locked','closed')),
 countdown_ends_at timestamptz, created_at timestamptz not null default now()
);
create table if not exists public.group_members (
 group_id uuid not null references public.groups(id) on delete cascade,
 player_id uuid not null references public.profiles(id) on delete cascade,
 joined_at timestamptz not null default now(), primary key(group_id,player_id)
);
create table if not exists public.payment_requests (
 id uuid primary key default gen_random_uuid(),
 player_id uuid not null references public.profiles(id) on delete cascade,
 request_type text not null check (request_type in ('buy','exchange')),
 coins bigint not null check (coins > 0), amount numeric(12,2) not null check (amount >= 0),
 account_details text, screenshot_path text,
 status text not null default 'pending' check (status in ('pending','approved','rejected','completed')),
 reviewed_by uuid references public.profiles(id) on delete set null, reviewed_at timestamptz,
 created_at timestamptz not null default now()
);
create table if not exists public.chat_messages (
 id uuid primary key default gen_random_uuid(),
 player_id uuid references public.profiles(id) on delete cascade,
 group_id uuid references public.groups(id) on delete cascade,
 message text not null check (char_length(message) between 1 and 1000),
 created_at timestamptz not null default now()
);
create table if not exists public.wallet_ledger (
 id uuid primary key default gen_random_uuid(),
 player_id uuid not null references public.profiles(id) on delete cascade,
 delta bigint not null check (delta <> 0), reason text not null, reference_id uuid,
 created_by uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now()
);
create index if not exists game_history_player_created_idx on public.game_history(player_id,created_at desc);
create index if not exists payment_requests_status_created_idx on public.payment_requests(status,created_at desc);
create index if not exists chat_messages_created_idx on public.chat_messages(created_at desc);
alter table public.profiles enable row level security;
alter table public.game_history enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.payment_requests enable row level security;
alter table public.chat_messages enable row level security;
alter table public.wallet_ledger enable row level security;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('payment-screenshots','payment-screenshots',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do nothing;
