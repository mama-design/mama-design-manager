const url = Deno.env.get('SUPABASE_URL')!;
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const bucket = 'mama-briefing-photos';
const origin = 'https://manager.mamadesign.com.br';
const maxPhoto = 3 * 1024 * 1024;
const maxFiles = 6;
const headers = {
  'Access-Control-Allow-Origin': origin,
  'Access-Control-Allow-Headers': 'content-type, authorization',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Cache-Control': 'no-store',
  'Content-Type': 'application/json; charset=utf-8',
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {status, headers});
const tokenPattern = /^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/i;

function db(path: string, options: RequestInit = {}) {
  return fetch(url + path, {
    ...options,
    headers: {apikey:key, Authorization:'Bearer '+key, ...options.headers},
  });
}

async function read(token: string) {
  const result = await db('/rest/v1/rpc/mama_briefing_read', {
    method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({p_token:token}),
  });
  if (!result.ok) throw Error('database read '+result.status);
  return await result.json();
}

async function save(action: string, token: string, answers?: Record<string,string>, photos?: string[]) {
  const result = await db('/rest/v1/rpc/mama_briefing_receive', {
    method:'POST', headers:{'Content-Type':'application/json'},
    body:JSON.stringify({p_token:token,p_action:action,p_answers:answers,p_photos:photos}),
  });
  if (!result.ok) throw Error('database write');
  return await result.json() === true;
}

async function imageType(file: File) {
  const a = new Uint8Array(await file.slice(0, 40).arrayBuffer());
  const letters = new TextDecoder().decode(a);
  if (a[0] === 255 && a[1] === 216 && a[2] === 255) return 'image/jpeg';
  if (a[0] === 137 && letters.slice(1,4) === 'PNG') return 'image/png';
  if (letters.startsWith('RIFF') && letters.slice(8,12) === 'WEBP') return 'image/webp';
  if (letters.slice(4,8) === 'ftyp' && /heic|heix|hevc|hevx|mif1|msf1/.test(letters.slice(8))) return 'image/heic';
  return null;
}

const fields: Record<string,number> = {
  title:200, event_date:10, start_time:5, end_time:5, theme:1500, colors:1000, style:1500,
  details:2500, venue:300, address:500, invite_phrase:1200, pieces:2500, links:3000,
};
const weddingFields = {wedding_story:1200,wedding_monogram:500,wedding_reception:1000,wedding_invite_details:1200};
const debutanteFields = {debutante_personality:1200,debutante_symbol:800,debutante_initials:40,debutante_monogram_details:800,debutante_moments:1000,debutante_invite_details:1200};
function readAnswers(form: FormData, invite: boolean, items: string, type: string) {
  const extra=type==='Casamento'?weddingFields:type==='15 anos'?debutanteFields:{};
  const answers: Record<string,string> = {};
  for (const [field, limit] of Object.entries({...fields,...extra})) {
    if ((!invite && (field === 'invite_phrase' || field.endsWith('_invite_details'))) || (!items && field === 'pieces')) continue;
    const value = form.get(field);
    if (typeof value === 'string' && value.trim()) answers[field] = value.trim().slice(0,limit);
  }
  const date = answers.event_date;
  if (!answers.title || !date || !/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;
  const day = new Date(date+'T00:00:00Z');
  if (!Number.isFinite(day.valueOf()) || day.toISOString().slice(0,10) !== date) return null;
  for (const time of [answers.start_time, answers.end_time]) {
    if (time && !/^([01]\d|2[0-3]):[0-5]\d$/.test(time)) return null;
  }
  if (answers.end_time && (!answers.start_time || answers.end_time <= answers.start_time)) return null;
  if (answers.links) {
    const links = answers.links.split(/\s+/);
    if (links.length > 12 || links.some(link => {
      try { return !['http:','https:'].includes(new URL(link).protocol); }
      catch { return true; }
    })) return null;
    answers.links = links.join('\n');
  }
  return answers;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null,{headers,status:204});
  if (req.method !== 'POST') return reply({error:'Método indisponível.'},405);
  const {searchParams} = new URL(req.url);
  const action = searchParams.get('action');
  const token = req.headers.get('authorization')?.replace(/^Bearer\s+/i,'') || '';
  if (!tokenPattern.test(token)) return reply({error:'Este link de briefing está inválido.'},404);
  const uploaded: string[] = [];
  let committed = false;
  try {
    const briefing = await read(token);
    if (!briefing) return reply({error:'Este link foi substituído ou não está mais disponível.'},404);
    if (briefing.submitted_at) return reply({submitted:true});
    if (action === 'read') return reply({
      type:briefing.event_type, closedOn:briefing.closed_on, package:briefing.package_name,
      briefingDue:briefing.briefing_due, promisedDue:briefing.promised_due,
      includesInvite:briefing.includes_invite, items:briefing.items, accepted:!!briefing.accepted_at,
    });
    if (action === 'accept') {
      const dates = await req.json();
      if (typeof dates?.briefing_due !== 'string' || typeof dates?.promised_due !== 'string' ||
        !await save('accept',token,{briefing_due:dates.briefing_due,promised_due:dates.promised_due})) {
        return reply({error:'Os prazos podem ter mudado. Reabra o link e confira as datas antes de continuar.'},409);
      }
      return reply({accepted:true});
    }
    if (action !== 'submit' || !briefing.accepted_at) return reply({error:'Confirme os prazos para enviar o briefing.'},403);
    if (Number(req.headers.get('content-length')) > maxPhoto * maxFiles + 65536) {
      return reply({error:'As fotos passaram do limite de tamanho.'},413);
    }
    const form = await req.formData();
    const answers = readAnswers(form,briefing.includes_invite,briefing.items,briefing.event_type);
    if (!answers || answers.event_date < briefing.closed_on) {
      return reply({error:'Confira o nome, a data, os horários e os links das referências.'},400);
    }
    const files = form.getAll('photos');
    if (files.length > maxFiles || files.some(file => !(file instanceof File) || file.size > maxPhoto || !file.size)) {
      return reply({error:'Escolha até 6 fotos de no máximo 3 MB cada.'},400);
    }
    const photos = await Promise.all((files as File[]).map(async file => ({file,type:await imageType(file)})));
    if (photos.some(photo => !photo.type)) return reply({error:'Use fotos em JPG, PNG, WebP ou HEIC.'},400);
    const folder = briefing.event_id+'/'+crypto.randomUUID();
    for (const [index, photo] of photos.entries()) {
      const extension = photo.type === 'image/jpeg' ? 'jpg' : photo.type!.split('/')[1];
      const path = folder+'/'+(index+1)+'.'+extension;
      const upload = await db('/storage/v1/object/'+bucket+'/'+path,{
        method:'POST',headers:{'Content-Type':photo.type!,'x-upsert':'false'},
        body:photo.file,
      });
      if (!upload.ok) throw Error('photo upload');
      uploaded.push(path);
    }
    committed = await save('submit',token,answers,uploaded);
    if (!committed) return reply({error:'O link foi alterado ou o briefing já foi recebido. Reabra a página para conferir.'},409);
    return reply({submitted:true});
  } catch (error) {
    console.warn('Briefing request failed',action,error instanceof Error ? error.name : 'unknown');
    return reply({error:'Não foi possível concluir agora. Suas respostas continuam nesta tela. Tente novamente.'},503);
  } finally {
    if (!committed && uploaded.length) {
      // A transport failure can follow a successful commit. Keep files if the saved record references them.
      try {
        const record = await read(token);
        const unused = uploaded.filter(path => !record?.photos?.includes(path));
        if (unused.length) await db('/storage/v1/object/'+bucket,{
          method:'DELETE',headers:{'Content-Type':'application/json'},body:JSON.stringify({prefixes:unused}),
        });
      } catch { /* Keep uncertain files private. */ }
    }
  }
});
