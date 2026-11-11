const studioStages={queue:'Na fila',creating:'Em criação',review:'Prévia enviada',adjustments:'Em ajustes',done:'Concluído'};
const studioProduction=new Map();
let studioSelectedDay=briefingLocalDay(),studioMonth=studioSelectedDay.slice(0,7);
let studioAgendaSequence=0;
let studioBusy=false;

function studioStage(event){
 return studioProduction.get(event.id)?.stage||(briefingRecords.get(event.id)?.preview_sent_at?'review':'queue');
}
function studioMatches(event){
 const text=(event.title+' '+(clientCache.find(c=>c.id===event.client_id)?.full_name||'')).toLocaleLowerCase('pt-BR');
 return text.includes($('agendaSearch').value.trim().toLocaleLowerCase('pt-BR'));
}
function studioDates(event){
 const b=briefingRecords.get(event.id);
 return b?[{kind:'internal',date:b.internal_due,label:'Meta interna'},{kind:'promised',date:b.promised_due,label:'Prazo da cliente'}]:
  event.identity_due_date?[{kind:'promised',date:event.identity_due_date,label:'Entrega'}]:[];
}
function studioCard(event,label,date){
 const client=clientCache.find(c=>c.id===event.client_id),b=briefingRecords.get(event.id);
 const late=date&&date<briefingLocalDay()&&studioStage(event)!=='done';
 return '<button type="button" class="studio-project" data-project="'+esc(event.id)+'"'+(canAccess('events','edit')?' draggable="true"':'')+'><strong>'+esc(event.title)+'</strong><small>'+esc(client?.full_name||'Cliente')+'</small>'+
  '<small>'+esc(b&&!b.submitted_at?'Aguardando briefing':studioStages[studioStage(event)])+'</small>'+
  (date?'<span class="project-date'+(late?' project-late':'')+'">'+esc(label)+' · '+briefingDate(date)+(late?' · Em atraso':'')+'</span>':'')+'</button>';
}
function renderStudioCalendar(){
 const [year,month]=studioMonth.split('-').map(Number);
 $('calendarMonth').textContent=new Intl.DateTimeFormat('pt-BR',{month:'long',year:'numeric',timeZone:'UTC'}).format(new Date(Date.UTC(year,month-1,1)));
 const firstDay=new Date(Date.UTC(year,month-1,1)).getUTCDay(),days=new Date(Date.UTC(year,month,0)).getUTCDate();
 const visible=eventCache.filter(event=>studioMatches(event)&&studioStage(event)!=='done');
 const marks=new Map();
 for(const event of visible)for(const entry of studioDates(event)){
  if(!marks.has(entry.date))marks.set(entry.date,[]);
  marks.get(entry.date).push(entry.kind);
 }
 const cells=Array.from({length:firstDay},()=>'<span class="calendar-empty"></span>');
 for(let day=1;day<=days;day++){
  const date=studioMonth+'-'+String(day).padStart(2,'0'),items=marks.get(date)||[];
  const dots=[...new Set(items)].map(kind=>'<i class="'+kind+'"></i>').join('');
  cells.push('<button type="button" data-calendar-day="'+date+'" aria-label="'+briefingDate(date)+', '+items.length+' agendamento(s)" aria-pressed="'+(date===studioSelectedDay)+'"'+(date===briefingLocalDay()?' aria-current="date"':'')+'>'+day+'<span class="calendar-dots" aria-hidden="true">'+dots+(items.length?'<span>'+items.length+'</span>':'')+'</span></button>');
 }
 $('calendarDays').innerHTML=cells.join('');
 const projects=[];
 for(const event of visible)for(const entry of studioDates(event))if(entry.date===studioSelectedDay)projects.push(studioCard(event,entry.label,entry.date));
 $('calendarDayTitle').textContent=studioSelectedDay===briefingLocalDay()?'Hoje · '+briefingDate(studioSelectedDay):briefingDate(studioSelectedDay);
 $('calendarDayCount').textContent=projects.length+' agendamento(s)';
 $('calendarDayProjects').innerHTML=projects.join('')||'<p class="muted">Um dia livre por aqui. Escolha outra data para ver os projetos.</p>';
}
function renderStudioBoard(){
 const selected=$('boardStage').value,today=briefingLocalDay();
 const visible=eventCache.filter(e=>studioMatches(e)&&(briefingRecords.has(e.id)||studioProduction.has(e.id)||e.event_date>=today||e.identity_due_date>=today));
 $('productionBoard').innerHTML=Object.entries(studioStages).filter(([key])=>!selected||selected===key).map(([key,label])=>{
  const projects=visible.filter(e=>studioStage(e)===key).sort((a,b)=>{
   const first=briefingRecords.get(a.id)?.internal_due||a.identity_due_date||'9999',second=briefingRecords.get(b.id)?.internal_due||b.identity_due_date||'9999';
   return first.localeCompare(second);
  });
  return '<section class="production-column" data-drop-stage="'+key+'"><h3>'+label+'<span>'+projects.length+'</span></h3>'+
   projects.map(e=>studioCard(e,'Meta',briefingRecords.get(e.id)?.internal_due||e.identity_due_date)).join('')+
   (!projects.length?'<p class="muted small">Nenhum projeto nesta etapa.</p>':'')+'</section>';
 }).join('');
}
function renderStudioFocus(){
 const waiting=[...briefingRecords.values()].filter(b=>!b.submitted_at).length;
 const scheduled=eventCache.filter(event=>{
  const briefing=briefingRecords.get(event.id);
  const stage=studioStage(event);
  return (!briefing||briefing.submitted_at)
   && ['queue','creating','adjustments'].includes(stage)
   && studioDates(event).some(entry=>entry.date);
 }).length;
 const creating=eventCache.filter(e=>['creating','adjustments'].includes(studioStage(e))).length;
 $('studioFocus').innerHTML='<button type="button" data-page="agenda"><strong>' +scheduled+'</strong>Prévias na agenda</button><button type="button" data-page="briefings"><strong>'+waiting+'</strong>Aguardando briefing</button><button type="button" data-page="agenda" data-start-board><strong>'+creating+'</strong>Em criação ou ajustes</button>';
}
async function loadStudioAgenda(){
 if(!api||!canAccess('events','view'))return;
 const sequence=++studioAgendaSequence,company=val('company'),records=[];
 for(let from=0;;from+=1000){
  const {data,error}=await api.from('event_production').select('event_id,stage,notes,updated_at').eq('company_id',company).order('event_id').range(from,from+999);
  if(sequence!==studioAgendaSequence||company!==val('company'))return;
  if(error){msg('agendaFeedback','Não foi possível carregar o quadro. '+error.message,true);return}
  records.push(...data);
  if(data.length<1000)break;
 }
 studioProduction.clear();
 for(const record of records)studioProduction.set(record.event_id,record);
 renderStudioCalendar();renderStudioBoard();renderStudioFocus();
}
function setStudioView(view){
 $('studioCalendar').hidden=view!=='calendar';$('studioBoard').hidden=view!=='board';
 document.querySelectorAll('[data-agenda-view]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.agendaView===view)));
}
document.querySelectorAll('[data-agenda-view]').forEach(b=>b.onclick=()=>setStudioView(b.dataset.agendaView));
$('agendaSearch').oninput=()=>{renderStudioCalendar();renderStudioBoard()};
$('boardStage').onchange=renderStudioBoard;
function shiftStudioMonth(amount){
 const [y,m]=studioMonth.split('-').map(Number),date=new Date(Date.UTC(y,m-1+amount,1));
 studioMonth=date.toISOString().slice(0,7);studioSelectedDay=studioMonth+'-01';renderStudioCalendar();
}
$('calendarPrev').onclick=()=>shiftStudioMonth(-1);$('calendarNext').onclick=()=>shiftStudioMonth(1);
$('calendarToday').onclick=()=>{studioSelectedDay=briefingLocalDay();studioMonth=studioSelectedDay.slice(0,7);renderStudioCalendar()};
$('calendarDays').onclick=e=>{const b=e.target.closest('[data-calendar-day]');if(b){studioSelectedDay=b.dataset.calendarDay;renderStudioCalendar()}};
function openStudioProject(id){
 const event=eventCache.find(e=>e.id===id);if(!event)return;
 const b=briefingRecords.get(id),client=clientCache.find(c=>c.id===event.client_id),record=studioProduction.get(id);
 $('projectDialogTitle').textContent=event.title;
 const field=(name,value)=>'<div><span>'+name+'</span><strong>'+esc(value||'A definir')+'</strong></div>';
 $('projectDialogBody').innerHTML='<p class="muted">'+esc(client?.full_name||'Cliente')+' · '+esc(event.event_type)+'</p><div class="briefing-dates">'+
  (b?field('Meta interna',briefingDate(b.internal_due))+field('Prévia combinada',briefingDate(b.promised_due)):field('Entrega',briefingDate(event.identity_due_date)))+
  field('Evento',briefingDate(event.event_date))+'</div>'+
  '<label>Etapa<select id="projectStage"'+(!canAccess('events','edit')?' disabled':'')+'>'+Object.entries(studioStages).map(([key,label])=>'<option value="'+key+'"'+(studioStage(event)===key?' selected':'')+'>'+label+'</option>').join('')+'</select></label>'+
  '<label>Anotações do projeto<textarea id="projectNotes" maxlength="5000"'+(!canAccess('events','edit')?' readonly':'')+'>'+esc(record?.notes||'')+'</textarea></label>'+
  (canAccess('events','edit')?'<button type="button" id="saveProject">Salvar andamento</button>':'')+
  (b?'<button type="button" class="secondary" id="projectBriefing">Ver briefing e referências</button>':'')+
  (canAccess('events','delete')?'<button type="button" class="secondary" id="projectDelete">Excluir evento</button>':'')+'<p id="projectStatus" role="status"></p>';
 if($('saveProject'))$('saveProject').onclick=()=>saveStudioProject(id,$('projectStage').value,$('projectNotes').value);
 if($('projectBriefing'))$('projectBriefing').onclick=()=>{$('projectDialog').close();document.querySelector('#managerNav [data-page="briefings"]').click();setTimeout(()=>{const card=$('brief-'+id);if(card){card.open=true;card.scrollIntoView({block:'nearest'})}},0)};
 if($('projectDelete'))$('projectDelete').onclick=()=>deleteStudioEvent(id);
 if(!$('projectDialog').open)$('projectDialog').showModal();
}
$('closeProjectDialog').onclick=()=>$('projectDialog').close();
async function saveStudioProject(id,stage,notes=null){
 if(studioBusy||!canAccess('events','edit'))return;
 studioBusy=true;
 const status=$('projectDialog').open?$('projectStatus'):$('agendaFeedback');status.textContent='Salvando…';
 try{
  const {error}=await api.rpc('mama_production_save',{p_event:id,p_stage:stage,p_notes:notes});
  if(error)throw error;
  studioProduction.set(id,{...studioProduction.get(id),stage,...(notes!==null?{notes}:{})});
  await loadEvents();status.textContent='Andamento salvo.';
 }catch(e){status.textContent=e.message}
 finally{studioBusy=false}
}
async function deleteStudioEvent(id){
 if(studioBusy||!canAccess('events','delete'))return;
 const event=eventCache.find(e=>e.id===id);if(!event)return;
 if(!confirm('Excluir o evento “'+event.title+'” e o briefing vinculado? Esta ação não pode ser desfeita.'))return;
 studioBusy=true;
 try{
  const {data,error}=await api.rpc('mama_event_delete',{p_event:id});
  if(error||!data)throw error||Error('O evento já foi excluído ou a exclusão não foi confirmada.');
  if($('projectDialog').open)$('projectDialog').close();
  briefingRecords.delete(id);studioProduction.delete(id);
  await loadEvents();
  msg('briefingAgendaStatus','Evento excluído.');msg('agendaFeedback','Evento excluído.');
 }catch(e){const status=$('projectStatus');if($('projectDialog').open&&status)status.textContent=e.message;else msg('briefingAgendaStatus',e.message,true)}
 finally{studioBusy=false}
}
document.addEventListener('click',e=>{
 const b=e.target.closest('[data-project]');if(b)openStudioProject(b.dataset.project);
 const remove=e.target.closest('[data-delete-brief]');if(remove)deleteStudioEvent(remove.dataset.deleteBrief);
 if(e.target.closest('[data-start-board]'))setStudioView('board');
});
$('productionBoard').addEventListener('dragstart',e=>{
 const card=e.target.closest('[data-project]');if(!card||!canAccess('events','edit'))return;
 e.dataTransfer.setData('text/plain',card.dataset.project);e.dataTransfer.effectAllowed='move';
});
$('productionBoard').addEventListener('dragover',e=>{const col=e.target.closest('[data-drop-stage]');if(col&&canAccess('events','edit')){e.preventDefault();col.classList.add('drag-over')}});
$('productionBoard').addEventListener('dragleave',e=>e.target.closest('[data-drop-stage]')?.classList.remove('drag-over'));
$('productionBoard').addEventListener('drop',e=>{
 const col=e.target.closest('[data-drop-stage]');if(!col)return;e.preventDefault();col.classList.remove('drag-over');
 const id=e.dataTransfer.getData('text/plain');if(eventCache.some(x=>x.id===id))saveStudioProject(id,col.dataset.dropStage);
});
$('company').addEventListener('change',()=>{studioProduction.clear();studioAgendaSequence++;$('projectDialog').close();$('productionBoard').replaceChildren();$('calendarDayProjects').replaceChildren();$('studioFocus').replaceChildren()});
