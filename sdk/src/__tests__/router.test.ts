import {
  findRoutes,
  findOptimalRoute,
  BRIDGE_TOPOLOGY,
  type BridgeEdge,
  type Route,
} from "../router";

describe("findRoutes", () => {
  it("returns empty hops for same source and destination", () => {
    const routes = findRoutes("avalanche-fuji", "avalanche-fuji");
    expect(routes).toHaveLength(1);
    expect(routes[0].hops).toHaveLength(0);
    expect(routes[0].totalLatency).toBe(0);
  });

  it("finds direct route between connected chains", () => {
    const routes = findRoutes("moonbase-alpha", "shibuya");
    expect(routes.length).toBeGreaterThan(0);

    const direct = routes.find((r) => r.hops.length === 1);
    expect(direct).toBeDefined();
    expect(direct!.hops[0].protocol).toBe("XCM");
  });

  it("finds multiple routes with different protocols", () => {
    // Avalanche Fuji → subnet has both AWM and Teleporter routes
    const routes = findRoutes("avalanche-fuji", "avalanche-fuji-subnet");
    expect(routes.length).toBeGreaterThanOrEqual(2);

    const protocols = routes.map((r) => r.protocols).flat();
    expect(protocols).toContain("AWM");
    expect(protocols).toContain("Teleporter");
  });

  it("sorts routes by latency ascending", () => {
    const routes = findRoutes("avalanche-fuji", "avalanche-fuji-subnet");
    for (let i = 1; i < routes.length; i++) {
      expect(routes[i].totalLatency).toBeGreaterThanOrEqual(
        routes[i - 1].totalLatency,
      );
    }
  });

  it("returns empty array when no route exists", () => {
    const routes = findRoutes("nonexistent-chain", "also-nonexistent");
    expect(routes).toHaveLength(0);
  });

  it("respects maxHops limit", () => {
    const routes = findRoutes("avalanche-fuji", "aurora-testnet", 1);
    for (const route of routes) {
      expect(route.hops.length).toBeLessThanOrEqual(1);
    }
  });

  it("finds multi-hop routes", () => {
    // avalanche-fuji → moonbase-alpha → shibuya requires 2 hops
    const routes = findRoutes("avalanche-fuji", "shibuya");
    const multiHop = routes.find((r) => r.hops.length === 2);
    expect(multiHop).toBeDefined();
    expect(multiHop!.totalLatency).toBeGreaterThan(0);
  });

  it("avoids cycles in route discovery", () => {
    const routes = findRoutes("moonbase-alpha", "shibuya");
    for (const route of routes) {
      const visited = new Set<string>();
      visited.add("moonbase-alpha");
      for (const hop of route.hops) {
        expect(visited.has(hop.destination)).toBe(false);
        visited.add(hop.destination);
      }
    }
  });

  it("accepts custom topology", () => {
    const custom: BridgeEdge[] = [
      {
        source: "chain-a",
        destination: "chain-b",
        protocol: "XCM",
        estimatedLatency: 10,
        active: true,
      },
      {
        source: "chain-b",
        destination: "chain-c",
        protocol: "IBC",
        estimatedLatency: 20,
        active: true,
      },
    ];
    const routes = findRoutes("chain-a", "chain-c", 3, custom);
    expect(routes).toHaveLength(1);
    expect(routes[0].hops).toHaveLength(2);
    expect(routes[0].totalLatency).toBe(30);
    expect(routes[0].protocols).toEqual(expect.arrayContaining(["XCM", "IBC"]));
  });

  it("ignores inactive edges", () => {
    const topology: BridgeEdge[] = [
      {
        source: "a",
        destination: "b",
        protocol: "AWM",
        estimatedLatency: 5,
        active: false,
      },
      {
        source: "a",
        destination: "b",
        protocol: "Teleporter",
        estimatedLatency: 10,
        active: true,
      },
    ];
    const routes = findRoutes("a", "b", 3, topology);
    expect(routes).toHaveLength(1);
    expect(routes[0].hops[0].protocol).toBe("Teleporter");
  });
});

describe("findOptimalRoute", () => {
  it("returns the fastest route", () => {
    const route = findOptimalRoute("avalanche-fuji", "avalanche-fuji-subnet");
    expect(route).not.toBeNull();
    expect(route!.hops[0].protocol).toBe("AWM"); // 5s vs 10s Teleporter
    expect(route!.totalLatency).toBe(5);
  });

  it("returns null for unreachable chains", () => {
    const route = findOptimalRoute("nonexistent", "also-nonexistent");
    expect(route).toBeNull();
  });

  it("returns same-chain route for identical source and destination", () => {
    const route = findOptimalRoute("avalanche-fuji", "avalanche-fuji");
    expect(route).not.toBeNull();
    expect(route!.hops).toHaveLength(0);
    expect(route!.totalLatency).toBe(0);
  });
});

describe("BRIDGE_TOPOLOGY", () => {
  it("has expected number of edges", () => {
    expect(BRIDGE_TOPOLOGY.length).toBe(11);
  });

  it("all edges have required fields", () => {
    for (const edge of BRIDGE_TOPOLOGY) {
      expect(edge.source).toBeTruthy();
      expect(edge.destination).toBeTruthy();
      expect(edge.protocol).toBeTruthy();
      expect(typeof edge.estimatedLatency).toBe("number");
      expect(edge.estimatedLatency).toBeGreaterThan(0);
      expect(typeof edge.active).toBe("boolean");
    }
  });

  it("covers all target ecosystems", () => {
    const protocols = new Set(BRIDGE_TOPOLOGY.map((e) => e.protocol));
    expect(protocols).toContain("AWM");
    expect(protocols).toContain("Teleporter");
    expect(protocols).toContain("XCM");
    expect(protocols).toContain("IBC");
    expect(protocols).toContain("Rainbow");
  });
});
