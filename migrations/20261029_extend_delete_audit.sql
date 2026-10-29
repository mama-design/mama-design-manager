-- Extensão da auditoria de exclusões para eventos e vendas.
-- Executar no SQL Editor depois de 20261029_delete_audit.sql.
-- Idempotente: pode ser executado novamente sem duplicar gatilhos.
drop trigger if exists manager_audit_events_delete on public.events;
create trigger manager_audit_events_delete
after delete on public.events
for each row execute function public.manager_audit_deleted_row();

drop trigger if exists manager_audit_sales_delete on public.sales;
create trigger manager_audit_sales_delete
after delete on public.sales
for each row execute function public.manager_audit_deleted_row();

-- Conferência de gatilhos ativos (O = habilitado)
select tgname as gatilho, tgrelid::regclass as tabela, tgenabled as ativo
from pg_trigger
where tgname like 'manager_audit_%_delete'
order by tgname;
