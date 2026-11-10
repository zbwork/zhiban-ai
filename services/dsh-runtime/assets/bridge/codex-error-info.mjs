/** Persist only fixed diagnostic tokens; never retain arbitrary upstream text. */
export const errorInfo = (error) => {
  const value=error?.codexErrorInfo;
  const allowed=new Set(['contextWindowExceeded','usageLimitExceeded','serverOverloaded','cyberPolicy','internalServerError','unauthorized','badRequest','threadRollbackFailed','sandboxError','other','httpConnectionFailed','responseStreamConnectionFailed','responseStreamDisconnected','responseTooManyFailedAttempts','activeTurnNotSteerable']);
  const key=typeof value==='string'?value:Object.keys(value??{})[0];
  const status=value?.[key]?.httpStatusCode;
  const message=String(error?.message??'').toLowerCase();
  const reason=message.includes('image')?'image_response':message.includes('tool')?'tool_response':message.includes('stream')?'stream_response':'unknown';
  const terms=['input_image','image_url','image','function_call_output','encrypted','reasoning','invalid_request','unsupported','parse','decrypt','verify','expected','array','string','missing','timeout','overloaded','rate limit','quota','400','401','403','429','500','502','503','stream disconnected'].filter(term=>message.includes(term));
  const fields = new Set(['id','type','status','output','sequence_number','response','item_id','output_index','content_index','delta','text','role','content','usage','call_id','name','arguments']);
  const missing = [...message.matchAll(/missing field [`'"]([a-z_]+)[`'"]/g)].map(match => match[1]).filter(field => fields.has(field));
  return {...(missing.length ? {missing_fields:[...new Set(missing)].sort()} : {}),kind:allowed.has(key)?key:'other',terms,...(Number.isInteger(status)&&status>=100&&status<=599?{http_status:status}:{}),reason};
};
