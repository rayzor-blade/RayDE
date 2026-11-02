/** Keep the old replica before re-entering the URL's authenticated workspace. */
export async function reopenWorkspace(client, flushStorage, {renew, reload = () => location.reload(), later = fn => setTimeout(fn, 60), timeout = 15000} = {}) {
  if (client?.invalidated?.code !== "workspace-changed" && typeof renew !== "function") throw new Error("This workspace does not need to be reopened.");
  let timer, expired = false;
  try {
    await Promise.race([
      (async () => {await Promise.all([...client.docs.values()].map(doc => doc.checkpoint()));await flushStorage();if (!expired) await renew?.();})(),
      new Promise((_,reject) => {timer=setTimeout(() => {expired=true;reject(new Error("Reopening is taking too long. Try again."));},timeout);}),
    ]);
  } finally {clearTimeout(timer);}
  later(reload);
  return {};
}
