import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createServer as createHTTPSServer } from "node:https";
import { buildStatus } from "./status.js";
import { createServer } from "node:http";
import { createServer as createTCPServer, type Socket } from "node:net";
import { afterEach, describe, expect, test, vi } from "vitest";
import { detectHttpsEndpoints, probeHttpEndpoints } from "./probes.js";

const servers: ReturnType<typeof createServer>[] = [];

afterEach(async () => {
  await Promise.all(
    servers.map(
      (server) =>
        new Promise<void>((resolve, reject) => {
          server.close((error) => (error ? reject(error) : resolve()));
        })
    )
  );
  servers.length = 0;
});

describe("probeHttpEndpoints", () => {
  test("bounds total time when a server keeps trickling incomplete headers", async () => {
    let socket: Socket | undefined;
    let interval: ReturnType<typeof setInterval> | undefined;
    const server = createTCPServer((connection) => {
      socket = connection;
      connection.on("error", () => {});
      connection.write("HTTP/1.1 200 OK\r\nX-Slow: ");
      interval = setInterval(() => connection.write("x"), 10);
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("expected TCP server address");
    // End the fixture even against the old inactivity-only timeout.
    const fallback = setTimeout(() => socket?.destroy(), 500);
    try {
      const startedAt = performance.now();
      const url = `http://127.0.0.1:${address.port}`;
      const results = await probeHttpEndpoints([url], 75);
      expect(results.get(url)?.status).toBe("timeout");
      expect(performance.now() - startedAt).toBeLessThan(300);
    } finally {
      clearTimeout(fallback);
      clearInterval(interval);
      socket?.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  test("closes a streaming response once status headers have been collected", async () => {
    let connectionClosed = false;
    const server = createServer((_request, response) => {
      response.writeHead(200);
      response.flushHeaders();
      const interval = setInterval(() => response.write("data: heartbeat\n\n"), 10);
      response.on("close", () => {
        clearInterval(interval);
        connectionClosed = true;
      });
    });
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("expected TCP server address");
    try {
      const url = `http://127.0.0.1:${address.port}`;
      const results = await probeHttpEndpoints([url]);
      expect(results.get(url)?.status).toBe("ok");
      await vi.waitFor(() => expect(connectionClosed).toBe(true), { timeout: 200, interval: 10 });
    } finally {
      server.closeAllConnections();
    }
  });

  test("classifies HTTP 500 as a reachable endpoint error", async () => {
    const server = createServer((_request, response) => {
      response.writeHead(500);
      response.end("internal server error");
    });
    servers.push(server);

    await new Promise<void>((resolve) => {
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    if (!address || typeof address === "string") {
      throw new Error("expected TCP server address");
    }

    const url = `http://127.0.0.1:${address.port}`;
    const results = await probeHttpEndpoints([url]);

    expect(results.get(url)).toEqual(
      expect.objectContaining({
        url,
        status: "http-error",
        statusCode: 500,
        remoteAddress: "127.0.0.1"
      })
    );
    expect(results.get(url)?.latencyMs).toBeGreaterThanOrEqual(0);
  });
});

describe("HTTPS scheme discovery", () => {
  test("opens self-signed HTTPS on an arbitrary port and preserves HTTP", async () => {
    const directory = mkdtempSync(path.join(tmpdir(), "portdeck-https-test-"));
    let secure: ReturnType<typeof createHTTPSServer> | undefined;
    let plain: ReturnType<typeof createServer> | undefined;
    try {
      execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", path.join(directory, "key.pem"), "-out", path.join(directory, "cert.pem"), "-days", "1", "-subj", "/CN=localhost"], { stdio: "ignore" });
      const methods: string[] = [];
      secure = createHTTPSServer({ key: readFileSync(path.join(directory, "key.pem")), cert: readFileSync(path.join(directory, "cert.pem")) }, (request, response) => {
        methods.push(request.method!);
        response.writeHead(404);
        response.end();
      });
      plain = createServer((_request, response) => response.end("hello"));
      await Promise.all([secure, plain].map((server) => new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))));
      const ports = [secure, plain].map((server) => {
        const address = server.address();
        if (!address || typeof address === "string") throw new Error("expected server address");
        return address.port;
      });
      const status = await buildStatus({
        generatedAt: new Date().toISOString(),
        processPorts: ports.map((port, index) => ({ pid: index + 1, processName: "node", port, protocol: "TCP", address: "127.0.0.1" })),
        processes: new Map(), dockerPorts: [], gitByCwd: new Map(), warnings: [],
        detectHttpsEndpoints
      });
      const secureService = status.unknown.find((service) => service.port === ports[0]);
      const plainService = status.unknown.find((service) => service.port === ports[1]);
      expect(secureService?.url).toBe(`https://127.0.0.1:${ports[0]}`);
      expect(secureService?.listeners?.[0]?.url).toBe(secureService?.url);
      expect(plainService?.url).toBe(`http://127.0.0.1:${ports[1]}`);
      expect(methods).toEqual(["HEAD"]);
      expect(secureService?.endpointHealth).toBeUndefined();
      // Detection does not turn off certificate verification for health checks.
      expect((await probeHttpEndpoints([secureService!.url!])).get(secureService!.url!)?.status).toBe("unreachable");
    } finally {
      await Promise.all([secure, plain].filter((server) => server !== undefined).map((server) => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      })));
      rmSync(directory, { recursive: true, force: true });
    }
  });

  test("bounds unresponsive listeners and deduplicates endpoints", async () => {
    const sockets: Socket[] = [];
    const server = createTCPServer((socket) => { sockets.push(socket); socket.on("error", () => {}); });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("expected server address");
    try {
      const url = `http://127.0.0.1:${address.port}`;
      const start = performance.now();
      expect(await detectHttpsEndpoints([url, url], 75)).toEqual(new Set());
      expect(performance.now() - start).toBeLessThan(400);
      expect(sockets).toHaveLength(1);
    } finally {
      sockets.forEach((socket) => socket.destroy());
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});
