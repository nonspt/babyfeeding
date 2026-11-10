// Independent sync coordinator. Storage adapter commits queue and acknowledgements atomically.
// `lease` is required to serialize multiple browser tabs; a conflict never silently overwrites.
export function createSyncEngine({api,store,session,notify=()=>{}}){
 let active=false;
 async function run(){
   if(active)return {status:'busy'};
   active=true;
   let lease;
   try{
     lease=await store.acquireLease();
     if(!lease)return {status:'busy'};
     const credentials=await session.getAccessToken();
     if(!credentials)return {status:'signed_out'};
     const family=await api.family(credentials);
     const binding=await store.getBinding();
     if(!binding)return {status:'not_enabled'};
     if(binding.familyId!==family)return {status:'wrong_family'};
     const first=await store.pullPlan();
     const before=await api.pull(credentials,first.since);
     // Inbound data never replaces an entity with pending local changes.
     await store.applyRemote(before,lease,first);
     for(;;){
       await store.renewLease(lease);
       const op=await store.nextOperation(lease);
       if(!op)break;
       if(op.conflict)return {status:'conflict',entityId:op.entityId};
       const result=op.kind==='finish'?await api.finish(credentials,op):await api.commit(credentials,op);
       if(!result.ok){
         await store.markConflict(op.opId,result,lease);
         notify({status:'conflict',entityId:op.entityId});
         return {status:'conflict',entityId:op.entityId};
       }
       // opId remains stable across failed responses and app restarts.
       await store.acknowledge(op.opId,result,lease);
     }
     const last=await store.pullPlan();
     await store.applyRemote(await api.pull(credentials,last.since),lease,last);
     notify({status:'synced'});
     return {status:'synced'};
   }catch(error){
     notify({status:'error',code:error.code||'storage'});
     return {status:'error',code:error.code||'storage'};
   }finally{
     if(lease){try{await store.releaseLease(lease)}catch(error){notify({status:'error',code:'lease_release'})}}
     active=false;
   }
 }
 return {run};
}
