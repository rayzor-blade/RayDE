/** Validate a public sample bundle before adding missing files to browser storage. */
export function samplePreset(value) {
  if (!value || value.version !== 1 || typeof value.name !== 'string' || value.name.length > 128 || !Array.isArray(value.entries) || value.entries.length > 256) throw new Error('Invalid sample workspace.');
  const safe = path => typeof path === 'string' && path.startsWith('/work/') && path.split('/').slice(1).every(part=>part && part !== '.' && part !== '..' && !part.includes('\\') && !part.includes('\0'));
  if (!safe(value.root) || !safe('/work/'+value.project) || !('/work/'+value.project).startsWith(value.root+'/')) throw new Error('Invalid sample workspace path.');
  let bytes=0;const paths=new Set();
  for (const entry of value.entries) {
    if (entry.path !== '/work' && entry.path !== value.root && !(safe(entry.path) && entry.path.startsWith(value.root+'/')) || paths.has(entry.path)) throw new Error('Invalid sample entry.');
    paths.add(entry.path);
    if (typeof entry.directory !== 'boolean' || entry.directory && entry.data != null || !entry.directory && (typeof entry.data !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(entry.data))) throw new Error('Invalid sample contents.');
    bytes += entry.data?.length ?? 0;
  }
  if (bytes > 2*1024*1024 || !value.entries.some(entry=>entry.path===value.root && entry.directory) || !value.entries.some(entry=>entry.path==='/work/'+value.project && !entry.directory)) throw new Error('Incomplete sample workspace.');
  return value;
}
export function seedSample(database, value) {
  const preset=samplePreset(value);
  return new Promise((resolve,reject)=>{
    const transaction=database.transaction('files','readwrite'),store=transaction.objectStore('files');
    transaction.oncomplete=()=>resolve();transaction.onerror=transaction.onabort=()=>reject(transaction.error??Error('Could not save the sample workspace.'));
    for(const entry of preset.entries){
      const request=store.get(entry.path);
      request.onsuccess=()=>{if(request.result===undefined)store.put(entry);else if(request.result.directory!==entry.directory)transaction.abort();};
    }
  });
}
