-- Mama Design Manager: auditoria de exclusões (executar no SQL Editor do Supabase)
-- Esta migração cria histórico automático para exclusões reais, inclusive feitas fora do Manager.
create table if not exists public.manager_delete_audit (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  table_name text not null,
  record_id text not null,
  deleted_at timestamptz not null default now(),
  deleted_by uuid,
  old_data jsonb not null
);
create index if not exists manager_delete_audit_company_date_idx
  on public.manager_delete_audit(company_id, deleted_at desc);
alter table public.manager_delete_audit enable row level security;
revoke all on public.manager_delete_audit from anon, authenticated;
grant select on public.manager_delete_audit to authenticated;
drop policy if exists manager_delete_audit_admin_read on public.manager_delete_audit;
create policy manager_delete_audit_admin_read on public.manager_delete_audit
for select to authenticated using (
  exists (
    select 1 from public.memberships m
    where m.company_id=manager_delete_audit.company_id
      and m.user_id=auth.uid()
      and m.role in ('owner','admin')
  )
);
create or replace function public.manager_audit_deleted_row()
returns trigger language plpgsql security definer
set search_path=public,pg_temp as $$
begin
  insert into public.manager_delete_audit
    (company_id,table_name,record_id,deleted_by,old_data)
  values (old.company_id,tg_table_name,old.id::text,auth.uid(),to_jsonb(old));
  return old;
end $$;
revoke all on function public.manager_audit_deleted_row() from public, anon, authenticated;
drop trigger if exists manager_audit_financial_entries_delete on public.financial_entries;
create trigger manager_audit_financial_entries_delete
after delete on public.financial_entries
for each row execute function public.manager_audit_deleted_row();
drop trigger if exists manager_audit_clients_delete on public.clients;
create trigger manager_audit_clients_delete
after delete on public.clients
for each row execute function public.manager_audit_deleted_row();
-- Auditoria de vendas e eventos pode ser habilitada quando os fluxos de exclusão forem validados.
