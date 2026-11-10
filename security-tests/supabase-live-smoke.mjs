// Live smoke test: creates synthetic users and feeding records; prints identifiers only for cleanup.
const url='https://fefkcjprfmqfgfmanlwc.supabase.co';
const key='sb_publishable_glY1yQQJ9rTHJZNUDFFp3w_NtH3j5Hk';
async function call(path,body,token){let r=await fetch(url+path,{method:'POST',headers:{apikey:key,'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body||{})});let v=await r.json();if(!r.ok)throw Error(`request ${path} failed: HTTP ${r.status}, code ${v.code||v.error_code||'unknown'}`);return v}
const rpc=(name,body,token)=>call('/rest/v1/rpc/'+name,body,token);
async function main(){let users=[];try{
for(let i=0;i<3;i++){let a=await call('/auth/v1/signup',{});if(!a.access_token||!a.user?.id)throw Error('anonymous identity incomplete');users.push(a)}
let [a,b,c]=users,created=await rpc('babyfeeding_family_create',{p_role:'father'},a.access_token);if(!created.ok||!/^\d{6}$/.test(created.code))throw Error('family create failed');
let fid=await rpc('babyfeeding_sync_family',{},a.access_token);console.log('SYNTHETIC_FAMILY',fid);console.log('SYNTHETIC_USERS',users.map(x=>x.user.id).join(','));
let joined=await rpc('babyfeeding_family_join',{p_role:'mother',p_code:created.code,p_expected_family:null},b.access_token);if(!joined.ok)throw Error('join failed');
let replay=await rpc('babyfeeding_family_join',{p_role:'mother',p_code:created.code,p_expected_family:null},c.access_token);if(replay.ok||replay.reason!=='invalid')throw Error('invitation was reusable');
let rid=crypto.randomUUID(),now=Date.now(),record={id:rid,type:'bottle',at:now,createdAt:now,updatedAt:now,version:1,amount:90};let w=await rpc('babyfeeding_sync_commit',{p_op_id:crypto.randomUUID(),p_entity_id:rid,p_expected_revision:0,p_payload:record,p_deleted:false},a.access_token);if(!w.ok)throw Error('record write failed');let rows=await rpc('babyfeeding_sync_pull',{p_after:'',p_since:null},b.access_token);if(!Array.isArray(rows)||!rows.some(x=>x.entity_id===rid&&x.payload.amount===90))throw Error('record did not sync');
let denied=false;try{await rpc('babyfeeding_sync_pull',{p_after:'',p_since:null},c.access_token)}catch(e){denied=true}if(!denied)throw Error('nonmember could read family data');
let timer={side:'left',paused:false,start:now,runningSince:now,leftMs:0,rightMs:0},tid=crypto.randomUUID();let t=await rpc('babyfeeding_sync_commit',{p_op_id:crypto.randomUUID(),p_entity_id:'active-nurse',p_expected_revision:0,p_payload:timer,p_deleted:false},a.access_token);if(!t.ok)throw Error('timer start failed');let n={id:tid,type:'nurse',at:now,createdAt:now,updatedAt:now,version:1,duration:1000,side:'left',leftDuration:1000,rightDuration:0},op=crypto.randomUUID(),args={p_op_id:op,p_record_id:tid,p_record_revision:0,p_timer_revision:t.revision,p_record:n};let finish=await rpc('babyfeeding_sync_finish',args,b.access_token),again=await rpc('babyfeeding_sync_finish',args,b.access_token);if(!finish.ok||!again.ok||finish.timer_revision!==again.timer_revision)throw Error('timer finish/replay failed');
console.log('PASS live signup, family join, single use, isolation, feeding, active timer and idempotent finish');
}catch(e){console.error('FAIL',e.message);process.exitCode=1}finally{if(users.length)console.log('CREATED_USER_IDS',users.map(x=>x.user.id).join(','))}}
main();

