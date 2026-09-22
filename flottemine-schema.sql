-- ==========================================================
-- FlotteMine — schéma Supabase
-- À exécuter dans Supabase → SQL Editor (une seule fois par projet)
-- ==========================================================

create extension if not exists "pgcrypto";

-- ========== ABONNEMENTS ==========
create table if not exists subscriptions (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null unique references auth.users(id) on delete cascade,
  trial_start timestamptz not null default now(),
  is_paid boolean not null default false,
  created_at timestamptz not null default now()
);
alter table subscriptions enable row level security;
drop policy if exists "own subscription" on subscriptions;
create policy "own subscription" on subscriptions for all
  using (owner = auth.uid()) with check (owner = auth.uid());

-- ========== VÉHICULES ==========
create table if not exists vehicles (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
  plate text not null,
  model text not null default 'Hilux GUN125',
  km integer not null default 0,
  last_service_km integer not null default 0,
  service_interval_km integer not null default 5000,
  availability text not null default 'disponible', -- disponible | en_maintenance
  maintenance_until date,
  created_at timestamptz not null default now()
);
alter table vehicles enable row level security;
drop policy if exists "own vehicles" on vehicles;
create policy "own vehicles" on vehicles for all
  using (owner = auth.uid()) with check (owner = auth.uid());

-- ========== INTERVENTIONS (historique entretien véhicules) ==========
create table if not exists interventions (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references vehicles(id) on delete cascade,
  description text not null,
  km_at_service integer,
  cost numeric,
  date date not null default current_date,
  created_at timestamptz not null default now()
);
alter table interventions enable row level security;
drop policy if exists "interventions via vehicle owner" on interventions;
create policy "interventions via vehicle owner" on interventions for all
  using (exists (select 1 from vehicles v where v.id = interventions.vehicle_id and v.owner = auth.uid()))
  with check (exists (select 1 from vehicles v where v.id = interventions.vehicle_id and v.owner = auth.uid()));

-- ========== PANNES ==========
create table if not exists breakdowns (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references vehicles(id) on delete cascade,
  description text not null,
  priority text not null default 'moyenne', -- urgente | moyenne | faible
  status text not null default 'ouverte', -- ouverte | en_cours | resolue
  voice_url text,
  photo_url text,
  reported_at date not null default current_date,
  resolved_at date,
  created_at timestamptz not null default now()
);
alter table breakdowns enable row level security;
drop policy if exists "breakdowns via vehicle owner" on breakdowns;
create policy "breakdowns via vehicle owner" on breakdowns for all
  using (exists (select 1 from vehicles v where v.id = breakdowns.vehicle_id and v.owner = auth.uid()))
  with check (exists (select 1 from vehicles v where v.id = breakdowns.vehicle_id and v.owner = auth.uid()));

-- ========== PIÈCES & STOCK ==========
create table if not exists parts (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  reference text,
  quantity integer not null default 0,
  min_quantity integer not null default 2,
  unit_price numeric,
  created_at timestamptz not null default now()
);
alter table parts enable row level security;
drop policy if exists "own parts" on parts;
create policy "own parts" on parts for all
  using (owner = auth.uid()) with check (owner = auth.uid());

-- ========== CHAUFFEURS ==========
create table if not exists drivers (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
  full_name text not null,
  matricule text,
  phone text,
  photo_url text,
  status text not null default 'sur_site', -- sur_site | repos | libreville | conge | absent
  site text,
  vehicle_id uuid references vehicles(id) on delete set null,
  status_since date not null default current_date,
  status_note text,
  license_number text,
  license_expiry date,
  created_at timestamptz not null default now()
);
alter table drivers enable row level security;
drop policy if exists "own drivers" on drivers;
create policy "own drivers" on drivers for all
  using (owner = auth.uid()) with check (owner = auth.uid());

-- ========== HISTORIQUE DES STATUTS CHAUFFEUR ==========
create table if not exists driver_status_history (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references drivers(id) on delete cascade,
  status text not null,
  note text,
  changed_at timestamptz not null default now()
);
alter table driver_status_history enable row level security;
drop policy if exists "history via driver owner" on driver_status_history;
create policy "history via driver owner" on driver_status_history for all
  using (exists (select 1 from drivers d where d.id = driver_status_history.driver_id and d.owner = auth.uid()))
  with check (exists (select 1 from drivers d where d.id = driver_status_history.driver_id and d.owner = auth.uid()));

create index if not exists idx_drivers_status on drivers(status);
create index if not exists idx_driver_status_history_driver on driver_status_history(driver_id);

-- ========== STORAGE (photos, notes vocales) ==========
insert into storage.buckets (id, name, public)
  values ('voice-notes', 'voice-notes', true) on conflict (id) do nothing;
insert into storage.buckets (id, name, public)
  values ('breakdown-photos', 'breakdown-photos', true) on conflict (id) do nothing;
insert into storage.buckets (id, name, public)
  values ('driver-photos', 'driver-photos', true) on conflict (id) do nothing;

drop policy if exists "flottemine authenticated upload" on storage.objects;
create policy "flottemine authenticated upload" on storage.objects for insert to authenticated
  with check (bucket_id in ('voice-notes','breakdown-photos','driver-photos'));

drop policy if exists "flottemine public read" on storage.objects;
create policy "flottemine public read" on storage.objects for select
  using (bucket_id in ('voice-notes','breakdown-photos','driver-photos'));

drop policy if exists "flottemine authenticated update" on storage.objects;
create policy "flottemine authenticated update" on storage.objects for update to authenticated
  using (bucket_id in ('voice-notes','breakdown-photos','driver-photos'));

drop policy if exists "flottemine authenticated delete" on storage.objects;
create policy "flottemine authenticated delete" on storage.objects for delete to authenticated
  using (bucket_id in ('voice-notes','breakdown-photos','driver-photos'));

-- ========== ÉVOLUTIONS — QR codes, catégories, rotation sur site ==========
-- Véhicules : catégorie (menu déroulant extensible) + numéro interne auto-incrémenté (pour le QR code)
alter table vehicles add column if not exists category text not null default 'Véhicule léger';
alter table vehicles add column if not exists fleet_number bigint generated always as identity;

-- Chauffeurs : code interne auto-incrémenté (pour le QR code) + durée de rotation sur site (jours)
alter table drivers add column if not exists driver_code bigint generated always as identity;
alter table drivers add column if not exists rotation_days integer not null default 14;
