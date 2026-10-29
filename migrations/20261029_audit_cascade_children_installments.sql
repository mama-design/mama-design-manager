-- Audita exclusões em cascata de filhos e parcelas de vendas.
-- Como essas tabelas não têm company_id, a empresa é obtida do registro pai.
-- Executar somente após verificar a existência de sales.company_id e clients.company_id.
create or replace function public.manager_audit_deleted_child()
returns trigger language plpgsql security definer
set search_path=public,pg_temp as $$
declare v_company uuid;
begin
  select c.company_id into v_company from public.clients c where c.id=old.client_id;
  if v_company is null then
    raise exception 'Auditoria: empresa do cliente não encontrada para filho %',old.id;
  end if;
  insert into public.manager_delete_audit(company_id,table_name,record_id,deleted_by,old_data)
  values(v_company,tg_table_name,old.id::text,auth.uid(),to_jsonb(old));
  return old;
end $$;

create or replace function public.manager_audit_deleted_installment()
returns trigger language plpgsql security definer
set search_path=public,pg_temp as $$
declare v_company uuid;
begin
  select s.company_id into v_company from public.sales s where s.id=old.sale_id;
  if v_company is null then
    raise exception 'Auditoria: empresa da venda não encontrada para parcela %',old.id;
  end if;
  insert into public.manager_delete_audit(company_id,table_name,record_id,deleted_by,old_data)
  values(v_company,tg_table_name,old.id::text,auth.uid(),to_jsonb(old));
  return old;
end $$;

revoke all on function public.manager_audit_deleted_child() from public,anon,authenticated;
revoke all on function public.manager_audit_deleted_installment() from public,anon,authenticated;

drop trigger if exists manager_audit_client_children_delete on public.client_children;
create trigger manager_audit_client_children_delete
before delete on public.client_children
for each row execute function public.manager_audit_deleted_child();

drop trigger if exists manager_audit_sale_installments_delete on public.sale_installments;
create trigger manager_audit_sale_installments_delete
before delete on public.sale_installments
for each row execute function public.manager_audit_deleted_installment();
