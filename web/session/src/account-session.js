/** Hosted sessions follow the cookie account; explicit local connections keep their own authority. */
export function followAccount(accounts, client, notify) {
  return accounts.subscribe(status => {
    notify(status);
    if (!client) return;
    if (!status.user) client.pauseAccount();
    else if (client.accountPaused) void client.resumeAccount().catch(error => {
      if (!client.invalidated) client.emit("disconnected", {message:error.message});
    });
  });
}
