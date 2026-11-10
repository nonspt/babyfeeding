// Network boundary. Credentials and payloads must never be written to logs.
export class SyncApiError extends Error {
  constructor(message,code,status=0){super(message);this.name='SyncApiError';this.code=code;this.status=status}
}
export function createSyncApi(config,{fetchImpl=fetch,timeoutMs=12000}={}) {
  const origin=new URL(config.url);
  if(origin.protocol!=='https:'||origin.pathname!=='/'||origin.search||origin.hash)throw new Error('同步服务地址无效');
  if(typeof config.publishableKey!=='string'||!config.publishableKey.startsWith('sb_publishable_'))throw new Error('客户端配置无效');
  async function request(path,{body,token}={}){
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),timeoutMs);
    try{
      const headers={'apikey':config.publishableKey,'Content-Type':'application/json'};
      if(token)headers.Authorization=`Bearer ${token}`;
      const response=await fetchImpl(new URL(path,origin),{method:'POST',headers,body:JSON.stringify(body??{}),signal:controller.signal,cache:'no-store'});
      let value;try{value=await response.json()}catch{throw new SyncApiError('同步服务返回了无法识别的响应','invalid_response',response.status)}
      if(!response.ok){const code=(response.status===401||(path.startsWith('/auth/v1/token')&&response.status===400))?'unauthorized':response.status===403?'forbidden':response.status===429?'rate_limited':response.status>=500?'server':'request';throw new SyncApiError(code==='unauthorized'?'登录已失效或账号密码不正确':code==='forbidden'?'该账号无权访问家庭数据':'同步请求未完成，请稍后重试',code,response.status)}
      return value;
    }catch(e){if(e instanceof SyncApiError)throw e;throw new SyncApiError(e.name==='AbortError'?'连接超时，记录保留在本机':'无法连接同步服务，记录保留在本机',e.name==='AbortError'?'timeout':'network')}
    finally{clearTimeout(timer)}
  }
  const validateSession=value=>{if(!value||typeof value.access_token!=='string'||typeof value.refresh_token!=='string'||typeof value.user?.id!=='string'||!Number.isFinite(value.expires_in))throw new SyncApiError('登录响应不完整','invalid_response');return {accessToken:value.access_token,refreshToken:value.refresh_token,userId:value.user.id,expiresAt:Date.now()+value.expires_in*1000}};
  return {
    async anonymous(){return validateSession(await request('/auth/v1/signup',{body:{}}))},
    async createFamily(token,role){if(!['father','mother'].includes(role))throw new SyncApiError('请选择角色','validation');return request('/rest/v1/rpc/babyfeeding_family_create',{token,body:{p_role:role}})},
    async joinFamily(token,role,code,expectedFamily=null){if(!['father','mother'].includes(role)||!/^\d{6}$/.test(code))throw new SyncApiError('请选择角色并填写六位加入码','validation');return request('/rest/v1/rpc/babyfeeding_family_join',{token,body:{p_role:role,p_code:code,p_expected_family:expectedFamily}})},
    async newInvite(token){return request('/rest/v1/rpc/babyfeeding_family_new_invite',{token})},
    async signIn(email,password){if(!email||!password)throw new SyncApiError('请填写邮箱和密码','validation');return validateSession(await request('/auth/v1/token?grant_type=password',{body:{email,password}}))},
    async refresh(refreshToken){return validateSession(await request('/auth/v1/token?grant_type=refresh_token',{body:{refresh_token:refreshToken}}))},
    async family(token){const value=await request('/rest/v1/rpc/babyfeeding_sync_family',{token});if(typeof value!=='string'||!/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/.test(value))throw new SyncApiError('家庭信息不可用','invalid_response');return value},
    async pull(token,since=null){const result=[];let after='';for(;;){const rows=await request('/rest/v1/rpc/babyfeeding_sync_pull',{token,body:{p_after:after,p_since:since}});if(!Array.isArray(rows)||rows.length>200)throw new SyncApiError('同步数据不可用','invalid_response');result.push(...rows);if(result.length>100000)throw new SyncApiError('家庭记录数量过多，请联系维护人员','record_limit');if(rows.length<200)return result;const last=rows[rows.length-1]?.entity_id;if(typeof last!=='string'||last<=after)throw new SyncApiError('同步数据顺序无效','invalid_response');after=last}},
    async finish(token,op){const value=await request('/rest/v1/rpc/babyfeeding_sync_finish',{token,body:{p_op_id:op.opId,p_record_id:op.recordId,p_record_revision:op.recordRevision,p_timer_revision:op.timerRevision,p_record:op.record}});if(!value||typeof value.ok!=='boolean'||!Number.isSafeInteger(value.timer_revision)||!Number.isSafeInteger(value.record_revision))throw new SyncApiError('同步结果不可用','invalid_response');return value},
    async commit(token,op){const value=await request('/rest/v1/rpc/babyfeeding_sync_commit',{token,body:{p_op_id:op.opId,p_entity_id:op.entityId,p_expected_revision:op.baseRevision,p_payload:op.payload,p_deleted:op.deleted}});if(!value||typeof value.ok!=='boolean'||!Number.isSafeInteger(value.revision)||value.revision<0)throw new SyncApiError('同步结果不可用','invalid_response');return value}
  };
}
