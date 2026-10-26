/** Keep the old replica before re-entering the URL's authenticated workspace. */
export async function reopenWorkspace(client, flushStorage, {reload = () => location.reload(), later = fn => setTimeout(fn, 60), timeout = 15000} = {}) {
  if (client?.invalidated?.code !== "workspace-changed") throw new Error("This workspace does not need to be reopened.");
  let timer;
  try {
    await Promise.race([
      (async () => {await Promise.all([...client.docs.values()].map(doc => doc.checkpoint()));await flushStorage();})(),
      new Promise((_,reject) => {timer=setTimeout(() => reject(new Error("Browser storage is taking too long. Try reopening again.")),timeout);}),
    ]);
  } finally {clearTimeout(timer);}
  later(reload);
  return {};
}
