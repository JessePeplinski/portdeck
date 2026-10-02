import { createServer } from "node:http";
import { createServer as createTCPServer, type Socket } from "node:net";
import { afterEach, describe, expect, test, vi } from "vitest";
import { probeHttpEndpoints } from "./probes.js";

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
