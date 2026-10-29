-- Diagnóstico seguro das políticas RLS (somente leitura).
-- Copie o resultado completo da primeira consulta; não inclui dados de clientes.
select
  c.relname as tabela,
  c.relrowsecurity as rls_ativo,
  c.relforcerowsecurity as rls_forcado,
  p.policyname as politica,
  p.cmd as operacao,
  p.roles as papeis,
  p.qual as condicao_using,
  p.with_check as condicao_check
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
left join pg_policies p on p.schemaname=n.nspname and p.tablename=c.relname
where n.nspname='public'
and c.relname in (
  'clients','client_children','events','sales','sale_installments',
  'financial_entries','manager_delete_audit'
)
order by c.relname,p.cmd,p.policyname;

-- Conferir permissões de execução das funções que participam da auditoria.
select
  n.nspname as schema,
  p.proname as funcao,
  p.prosecdef as security_definer,
  has_function_privilege('authenticated',p.oid,'EXECUTE') as autenticado_pode_executar
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
and p.proname='manager_audit_deleted_row';
