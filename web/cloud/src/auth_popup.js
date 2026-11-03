const notification = new BroadcastChannel('rayde-auth:' + channel);
notification.postMessage({type: 'rayde-auth-complete', channel, status});
notification.close();
setTimeout(() => window.close(), 100);
