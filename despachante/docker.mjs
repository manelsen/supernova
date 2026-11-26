// The smallest Docker Engine API client the dispatcher needs: JSON over the
// Unix socket. Nothing else in Supernova speaks to Docker.

import http from 'node:http';

export function docker(socketPath) {
  function request(method, path, body) {
    return new Promise((resolve, reject) => {
      const payload = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
      const req = http.request({
        socketPath,
        method,
        path,
        headers: payload
          ? { 'content-type': 'application/json', 'content-length': payload.length }
          : {},
      }, (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          let json = null;
          try { json = text ? JSON.parse(text) : null; } catch { json = null; }
          resolve({ status: res.statusCode, body: json, text });
        });
      });
      req.on('error', reject);
      req.setTimeout(60_000, () => req.destroy(new Error('docker did not answer')));
      if (payload) req.write(payload);
      req.end();
    });
  }
  return { request };
}
