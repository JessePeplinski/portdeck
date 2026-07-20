import { createServer } from "node:http";
import { afterEach, describe, expect, test } from "vitest";
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
