const briefingRecords=new Map();
const briefingSales=new Map();
let briefingLoadSequence=0;
let briefingRequestId;
function eventHasBriefing(id){return briefingRecords.has(id)}

function briefingLocalDay(){
 return new Intl.DateTimeFormat('en-CA',{timeZone:'America/Sao_Paulo',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
}
function briefingDate(value){return value?value.slice(0,10).split('-').reverse().join('/'):'A definir'}
function briefingTimestamp(value){
 return value?new Intl.DateTimeFormat('pt-BR',{dateStyle:'short',timeStyle:'short',timeZone:'America/Sao_Paulo'}).format(new Date(value)):'—';
}
function canCreateBriefing(){
 return canAccess('events','create')&&canAccess('clients','view')&&canAccess('packages','view')&&canAccess('sales','create');
}
function syncBriefingAccess(){
 $('newBriefing').hidden=!canCreateBriefing();
 if(!canCreateBriefing())$('briefingCreateCard').classList.add('hidden');
}
function availableBriefingPackages(){
 return packagesCache.filter(p=>p.active&&/infantil|social/i.test(p.event_type||''));
}
function briefingLink(token){return new URL('/briefing.html#'+token,location.origin).href}
function showBriefingLink(token){
 const box=$('briefingShare');box.hidden=false;
 $('briefingCopyStatus').textContent='';
 $('briefingShareLink').value=briefingLink(token);
 box.scrollIntoView({block:'nearest'});
}
$('copyBriefingLink').onclick=async()=>{
 const input=$('briefingShareLink');
 try{await navigator.clipboard.writeText(input.value);$('briefingCopyStatus').textContent='Link copiado.'}
 catch{input.focus();input.select();$('briefingCopyStatus').textContent='Selecione e copie o link acima.'}
};
function setBriefingPackage(){
 const p=availableBriefingPackages().find(x=>x.id===val('briefingPackage'));
 $('briefingInvite').value=p?.briefing_invite==null?'':String(p.briefing_invite);
 $('briefingItems').value=p?.briefing_items||'';
 $('briefingSalePreview').textContent=p?'Venda a receber de '+brl(p.price)+', com vencimento na data do fechamento. Você pode editar no Financeiro.':'';
}
function showBriefingClientRule(){
 const c=clientCache.find(x=>x.id===val('briefingClient'));
 $('briefingClientDays').value=String(c?.briefing_business_days||10);
 $('briefingClientRule').hidden=!c;
 $('briefingClientDays').disabled=!canAccess('clients','edit');
 $('briefingSaveRule').hidden=!canAccess('clients','edit');
}
$('briefingPackage').onchange=setBriefingPackage;
$('briefingClient').onchange=showBriefingClientRule;
$('briefingSaveRule').onclick=async()=>{
 const client=clientCache.find(x=>x.id===val('briefingClient')),button=$('briefingSaveRule');
 if(!client||button.disabled||!canAccess('clients','edit'))return;
 button.disabled=true;
 const days=Number(val('briefingClientDays'));
 try{
  const {data,error}=await api.from('clients').update({briefing_business_days:days})
   .eq('company_id',val('company')).eq('id',client.id).select('id').single();
  if(error||!data)throw error||Error('Não foi possível salvar a regra.');
  client.briefing_business_days=days;
  msg('briefingCreateStatus','Prazo padrão salvo para esta cliente.');
 }catch(e){msg('briefingCreateStatus',e.message,true)}
 finally{button.disabled=false}
};
$('newBriefing').onclick=async()=>{
 if(!canCreateBriefing())return;
 const button=$('newBriefing');button.disabled=true;
 try{
  await Promise.all([loadClients(),loadCommercial()]);
  const options=availableBriefingPackages();
  if(!canCreateBriefing())return;
  if(!clientCache.length||!options.length){
   msg('briefingAgendaStatus','Cadastre uma cliente e um pacote ativo de infantil ou social para gerar um briefing.',true);return;
  }
  $('briefingCreate').reset();
  briefingRequestId=crypto.randomUUID();
  $('briefingClient').innerHTML='<option value="">Selecione</option>'+clientCache.map(c=>'<option value="'+esc(c.id)+'">'+esc(c.full_name)+'</option>').join('');
  $('briefingPackage').innerHTML='<option value="">Selecione</option>'+options.map(p=>'<option value="'+esc(p.id)+'">'+esc(p.name)+'</option>').join('');
  $('briefingClosed').value=briefingLocalDay();$('briefingClosed').max=$('briefingClosed').value;
  showBriefingClientRule();setBriefingPackage();
  msg('briefingCreateStatus','');
  $('briefingCreateCard').classList.remove('hidden');
  if(!openMobileForm('briefingCreateCard','Novo briefing'))$('briefingCreateCard').scrollIntoView({block:'nearest'});
 }catch(e){msg('briefingAgendaStatus',e.message,true)}
 finally{button.disabled=false}
};
$('cancelBriefing').onclick=()=>$('briefingCreateCard').classList.add('hidden');
$('briefingCreate').onsubmit=async e=>{
 e.preventDefault();const b=$('createBriefingLink');
 if(b.disabled||!canCreateBriefing())return;
 const client=clientCache.find(x=>x.id===val('briefingClient'));
 if(!client||String(client.briefing_business_days||10)!==val('briefingClientDays')){
  msg('briefingCreateStatus','Salve a regra de prazo da cliente antes de gerar o link.',true);return;
 }
 b.disabled=true;
 try{
  const {data,error}=await api.rpc('mama_briefing_create',{
   p_company:val('company'),p_client:client.id,p_package:val('briefingPackage'),
   p_type:val('briefingType'),p_closed:val('briefingClosed'),p_request:briefingRequestId,p_override:val('briefingUrgency')||null,
   p_invite:val('briefingInvite')==='true',p_items:val('briefingItems').trim()
  });
  if(error||!data?.token)throw error||Error('Link não confirmado.');
  $('briefingCreateCard').classList.add('hidden');
  showBriefingLink(data.token);
  await loadCommercial();
  await loadEvents();
 }catch(e){msg('briefingCreateStatus','Não foi possível criar o briefing. '+e.message,true)}
 finally{b.disabled=false}
};

function briefingCard(b,ev,client,today){
 const answers=b.answers||{};
 const sale=briefingSales.get(b.event_id);
 const received=sale?(sale.sale_installments||[]).reduce((n,i)=>n+Number(i.paid_amount||0),0):0;
 const financial=sale&&(canAccess('sales','view')||canAccess('finance','view'))
  ?'<p class="small">'+brl(sale.total_amount)+' · '+((sale.status==='cancelled')?'Venda cancelada':received>=Number(sale.total_amount)?'Recebido':received>0?'Recebido '+brl(received)+' · A receber '+brl(Number(sale.total_amount)-received):'A receber')+'</p>'+
   (currentRole()==='owner'&&canAccess('finance','view')?'<button type="button" class="secondary" data-page="finance" data-receipt-month="'+esc((sale.sale_installments?.[0]?.due_date||b.closed_on).slice(0,7))+'">Ver no Financeiro</button>':'')
  :!sale&&canAccess('sales','create')?'<button type="button" class="secondary" data-brief-sale="'+b.event_id+'">Gerar venda a receber</button>':'';

 const late=(b.submitted_at
  ?new Intl.DateTimeFormat('en-CA',{timeZone:'America/Sao_Paulo',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(b.submitted_at))
  :today)>b.briefing_due;
 const conflict=ev.event_date&&b.promised_due>=ev.event_date;
 const state=b.preview_sent_at?'Prévia enviada':b.submitted_at?'Briefing recebido':late?'Briefing atrasado':'Aguardando briefing';
 const edit=canAccess('events','edit');
 const dateField=(label,date)=>'<div><span>'+label+'</span><strong>'+briefingDate(date)+'</strong></div>';
 const info=(label,value)=>value?'<div class="briefing-answer"><strong>'+label+'</strong><p>'+esc(value)+'</p></div>':'';
 const links=String(answers.links||'').split(/\s+/).filter(x=>/^https?:\/\//i.test(x));
 const photoAction=b.photos?.length?'<button class="secondary" type="button" data-brief-photos="'+b.event_id+'">Ver '+b.photos.length+' foto(s)</button><div class="briefing-photos" data-brief-photo-box="'+b.event_id+'"></div>':'';
 return '<details class="briefing-record" id="brief-'+b.event_id+'"><summary><span><strong>'+esc(ev.title)+'</strong>'+
  '<small>'+esc(client?.full_name||ev.event_type)+' · '+esc(b.package_name)+'</small></span><span class="briefing-state'+(late?' briefing-alert':'')+'">'+state+'</span></summary>'+
  '<div class="briefing-dates">'+dateField('Meta interna',b.internal_due)+dateField('Prévia combinada',b.promised_due)+dateField('Receber briefing',b.briefing_due)+dateField('Dia do evento',ev.event_date)+'</div>'+
  (late?'<p class="briefing-alert-text">Briefing '+(b.submitted_at?'recebido depois do prazo':'em atraso')+'. Revise a entrega se necessário.</p>':'')+
  (conflict?'<p class="briefing-alert-text">A entrega prevista cai no dia do evento ou depois. Revise a data.</p>':'')+
  financial+'<p class="muted small">Leitura confirmada em '+briefingTimestamp(b.accepted_at)+' · Envio '+briefingTimestamp(b.submitted_at)+'</p>'+
  (canAccess('events','delete')?'<div class="toolbar"><button type="button" class="secondary" data-delete-brief="'+b.event_id+'">Excluir evento</button></div>':'')+
  (edit&&!b.submitted_at?'<div class="toolbar"><button class="secondary" type="button" data-brief-action="link" data-brief-id="'+b.event_id+'">Copiar link</button><button class="secondary" type="button" data-brief-action="renew" data-brief-id="'+b.event_id+'">Gerar novo link</button></div>':'')+
  (edit&&!b.preview_sent_at?'<div class="toolbar briefing-controls"><label>Prazo combinado<input type="date" data-brief-date="'+b.event_id+'" min="'+b.closed_on+'" value="'+b.promised_due+'"></label><button class="secondary" type="button" data-brief-action="deadline" data-brief-id="'+b.event_id+'">Atualizar prazo</button>'+
    (b.submitted_at?'<button type="button" data-brief-action="sent" data-brief-id="'+b.event_id+'">Marcar prévia enviada</button>':'')+'</div>':'')+
  (b.submitted_at?'<div class="briefing-answers">'+info('Horário',ev.start_time?.slice(0,5))+info('Local',ev.venue_name)+info('Endereço',ev.venue_address)+
   info('Tema',answers.theme)+info('Cores',answers.colors)+info('Estilo',answers.style)+info('Detalhes criativos',answers.details)+info('Frase do convite',answers.invite_phrase)+info('Peças combinadas',b.items)+info('Detalhes das peças',answers.pieces)+
   (links.length?'<div class="briefing-answer"><strong>Links de referência</strong>'+links.map((x,i)=>'<a href="'+esc(x)+'" target="_blank" rel="noopener noreferrer">Abrir referência '+(i+1)+'</a>').join('')+'</div>':'')+
   photoAction+'</div>':'')+'</details>';
}
async function loadBriefingAgenda(){
 syncBriefingAccess();
 if(!canAccess('events','view'))return;
 const sequence=++briefingLoadSequence,company=val('company');
 const records=[];
 for(let from=0;;from+=1000){
  const {data,error}=await api.from('event_briefings').select('event_id,package_name,closed_on,briefing_due,promised_due,internal_due,items,accepted_at,submitted_at,preview_sent_at,answers,photos')
   .eq('company_id',company).order('internal_due').order('event_id').range(from,from+999);
  if(sequence!==briefingLoadSequence||company!==val('company'))return;
  if(error){msg('briefingAgendaStatus','Não foi possível carregar os briefings. '+error.message,true);return}
  records.push(...data);
  if(data.length<1000)break;
 }
 if(sequence!==briefingLoadSequence||company!==val('company'))return;
 briefingSales.clear();
 if(canAccess('sales','view')||canAccess('sales','create')||canAccess('finance','view')){
  for(let from=0;;from+=1000){
   const result=await api.from('sales').select('id,event_id,total_amount,status,sale_installments(due_date,paid_amount)').eq('company_id',company).order('id').range(from,from+999);
   if(sequence!==briefingLoadSequence||company!==val('company'))return;
   if(result.error){msg('briefingAgendaStatus','Não foi possível conferir as vendas vinculadas. '+result.error.message,true);break}
   for(const sale of result.data||[])if(sale.event_id)briefingSales.set(sale.event_id,sale);
   if((result.data||[]).length<1000)break;
  }
 }
 briefingRecords.clear();
 const open=new Set([...$('briefingAgenda').querySelectorAll('details[open]')].map(x=>x.id));
 const current=[],history=[],today=briefingLocalDay(),events=new Map(eventCache.map(x=>[x.id,x]));
 for(const b of records){
  const ev=events.get(b.event_id);
  if(!ev)continue;
  briefingRecords.set(b.event_id,b);
  const html=briefingCard(b,ev,clientCache.find(x=>x.id===ev.client_id),today);
  (b.preview_sent_at?history:current).push(html);
 }
 $('briefingAgenda').innerHTML=(current.join('')||'<p class="muted small">Nenhum briefing ou prévia pendente.</p>')+
  (history.length?'<details class="briefing-history" id="briefingHistory"><summary>Prévias enviadas ('+history.length+')</summary>'+history.reverse().join('')+'</details>':'');
 for(const id of open){const details=$(id);if(details)details.open=true}
 filterBriefingCards();
}
$('briefingAgenda').onclick=async e=>{
 const photosButton=e.target.closest('[data-brief-photos]');
 const actionButton=e.target.closest('[data-brief-action]');
 const button=photosButton||actionButton;
 if(!button||button.disabled)return;
 button.disabled=true;
 try{
  if(photosButton){
   const id=button.dataset.briefPhotos,b=briefingRecords.get(id);
   if(!b)return;
   const {data,error}=await api.storage.from('mama-briefing-photos').createSignedUrls(b.photos,300);
   if(error||data?.some(item=>!item.signedUrl))throw error||Error('Uma das fotos está indisponível.');
   const box=$('brief-'+id).querySelector('[data-brief-photo-box]');
   box.replaceChildren(...data.map((item,index)=>{
    const link=document.createElement('a'),img=document.createElement('img');
    link.href=item.signedUrl;link.target='_blank';link.rel='noopener noreferrer';
    img.src=item.signedUrl;img.alt='Referência '+(index+1);
    img.onerror=()=>img.remove();
    link.append(img,'Abrir foto '+(index+1));return link;
   }));
   return;
  }
  if(!canAccess('events','edit'))return;
  const {briefAction,briefId}=button.dataset;
  if(briefAction==='renew'&&!confirm('Gerar um novo link? O link anterior deixará de funcionar.'))return;
  const dateInput=$('brief-'+briefId).querySelector('[data-brief-date]');
  if(briefAction==='deadline'&&(!dateInput.value||!dateInput.reportValidity()))return;
  const {data,error}=await api.rpc('mama_briefing_manage',{
   p_event:briefId,p_action:briefAction,p_date:briefAction==='deadline'?dateInput.value:null
  });
  if(error)throw error;
  if(data){
   showBriefingLink(data);
   if(briefAction==='link'){
    try{await navigator.clipboard.writeText(briefingLink(data));$('briefingCopyStatus').textContent='Link copiado.'}
    catch{$('briefingShareLink').focus();$('briefingShareLink').select()}
   }
   if(briefAction==='renew')await loadBriefingAgenda();
  }else await loadEvents();
 }catch(error){msg('briefingAgendaStatus',error.message,true)}
 finally{button.disabled=false}
};

$('company').addEventListener('change',()=>{
 briefingRecords.clear();
 $('briefingShare').hidden=true;
 $('briefingShareLink').value='';
 $('briefingCreateCard').classList.add('hidden');
 $('briefingAgenda').replaceChildren();
});

function filterBriefingCards(){
 const query=$('briefingSearch').value.trim().toLocaleLowerCase('pt-BR');
 $('briefingAgenda').querySelectorAll('.briefing-record').forEach(card=>{
  card.hidden=!card.textContent.toLocaleLowerCase('pt-BR').includes(query);
 });
 if(query&&$('briefingHistory'))$('briefingHistory').open=true;
}
$('briefingSearch').addEventListener('input',filterBriefingCards);

document.addEventListener('click',async e=>{
 const button=e.target.closest('[data-brief-sale]');
 if(!button||button.disabled||!canAccess('sales','create'))return;
 button.disabled=true;
 try{
  const {data,error}=await api.rpc('mama_briefing_sale',{p_event:button.dataset.briefSale});
  if(error||!data)throw error||Error('A venda não foi confirmada.');
  await loadCommercial();await loadBriefingAgenda();
  msg('briefingAgendaStatus','Venda vinculada ao Financeiro como a receber.');
 }catch(e){msg('briefingAgendaStatus',e.message,true)}
 finally{button.disabled=false}
});
