// Compiled by the check suite, never run. If a change to the typings breaks normal usage, this
// file stops compiling

import Geode from "../types";

const playerData = Geode.players({
	name: "PlayerData",
	template: { coins: 0, xp: 0, level: 1, inventory: [] },
	kickMessage: "Something went wrong with your data. Please rejoin.",
	replicate: { coins: "owner", level: "public" },
	products: {
		[123456]: (tx) => {
			tx.increment("coins", 1000);
		},
	},
});

playerData.onLoaded((player, profile) => {
	profile.increment("coins", 100);
	print(player.Name, profile.get("coins"));
});

// the types are reachable through the namespace
function grant(profile: Geode.Profile, amount: number): Geode.TxResult {
	return profile.increment("coins", amount);
}
const store: Geode.ProfileStore = playerData.store;
const first = store.get("player_1");
if (first !== undefined) {
	grant(first, 5);
}

const handle = playerData.get(game.GetService("Players").GetPlayers()[0]);
if (handle?.isLoaded() === true) {
	handle.set("level", 2);
}

const guilds = Geode.Shared.store({
	name: "Guilds",
	template: { bank: 0 },
	guards: [
		Geode.guard.range("bank", { min: 0 }, { action: "kick", kickMessage: "Please rejoin." }),
	],
	kickMessage: "Your guild data had a problem. Please rejoin.",
});
const deposit = guilds.increment("guild_1", "bank", 50);
if (!deposit.ok) {
	warn(deposit.error.message);
}

const schema = Geode.t.struct({ coins: Geode.t.integer({ min: 0 }), pos: Geode.codec.Vector3 });
const [decoded, value] = Geode.schema.decode(schema, {});
print(decoded, value);

const daily = Geode.Ranked.windowed("Daily", { window: "daily", mode: "max" });

Geode.setup({ studio: "auto" });
const studioMode: Geode.StudioMode = "auto";
Geode.Shared.store({ name: "Clans", template: { bank: 0 }, studio: studioMode });
const wins = Geode.Ranked.allTime("Wins", { studio: "mock", scope: "season2" });
print(wins.scope);
const off: Geode.Result<undefined> = wins.remove(1001);
const homes = Geode.Shared.store({
	name: "Homes",
	template: { rooms: 1 },
	keyForUser: (userId) => `home_${tostring(userId)}`,
});
const deleted = homes.delete("home_1001");
const report = Geode.erase(1001);
for (const entry of report.stores) {
	const kind: Geode.ErasableKind = entry.kind;
	print(entry.store, kind, entry.ok, entry.message, off.ok, deleted.ok);
}
Geode.setup({ studio: "auto", scope: "test" });
Geode.Ephemeral.hashMap("Cache", { studio: "scope" });
Geode.Counter.new("Visits", { studio: "real" });
Geode.Matchmaker.new({ name: "duel", placeId: 1, matchSize: 2, studio: "mock" });
const top = daily.top(10);
if (top.ok) {
	for (const entry of top.value) {
		print(entry.userId, entry.score);
	}
}

const lock = Geode.Mutex.new("Boss").acquire("spawn", 5);
if (lock.ok && lock.value !== undefined) {
	lock.value.release();
}

Geode.op(
	"grantItem",
	(tx, itemId: string, amount: number) => {
		tx.increment(["inventory", itemId], amount);
	},
	{
		args: [Geode.t.string(), Geode.t.integer({ min: 1 })],
		names: ["itemId", "amount"],
		description: "Give the player some of an item",
	},
);
Geode.remoteOp("buyItem", { store: playerData.store, args: [Geode.t.string()] });

const client = Geode.Client.start();
const coins = client.atom("coins");
coins.subscribe((newValue) => {
	print(newValue);
});
client.op("buyItem", "sword");

print(Geode.Vein.snapshot().idle);

const edited = Geode.Raw.externalWrite(
	{ data: { coins: 5 }, meta: { schemaVersion: 1, revision: 7 } },
	{ coins: 50 },
	{ now: DateTime.now().UnixTimestampMillis / 1000, id: "edit-1" },
);
print(edited.meta.revision, edited.meta.format === Geode.Raw.recordFormat);

const universe = Geode.Testing.universe({ dataStoreCache: { seconds: 4 } });
const server = universe.server();
server.inject({ service: "dataStore", method: "update", fault: "throttle", times: 1 });
const mailStore = Geode.Profile.store({
	name: "Mail",
	template: { coins: 0 },
	services: server,
	mailbox: true,
});
const queued = mailStore.mail("player_1", "increment", "coins", 5);
if (queued.ok) {
	print(queued.value);
}
universe.clock.run(() => {
	const loaded = mailStore.load("player_1");
	if (loaded.ok) {
		loaded.profile.release();
	}
});

const closing: Geode.BeforeRelease = (tx, profile, reason) => {
	tx.set("lastSeen", os.time());
	tx.set("closedBy", reason);
	print(profile.key);
};
const sessionStore = Geode.Profile.store({
	name: "Sessions",
	template: { lastSeen: 0, closedBy: "" },
	services: server,
	beforeRelease: closing,
});
universe.clock.run(() => {
	const loaded = sessionStore.load("player_1");
	if (loaded.ok) {
		const reason: Geode.ReleaseReason = "release";
		loaded.profile.release(reason);
	}
	sessionStore.releaseAll("shutdown");
	const finished: number = sessionStore.destroy();
	const refused = sessionStore.load("player_2");
	if (!refused.ok && refused.error.kind === "destroyed") {
		print(finished);
	}
});
const fresh = server.dataStore("Mail").get("player_1", { useCache: false });
if (fresh.ok) {
	print(fresh.value.value, fresh.value.info?.version);
}
print(universe.kicks.size(), server.tooling.messages().size());

const [valid, result] = Geode.schema.decode(Geode.t.number(), 1);
if (!valid) {
	print(result.issues[0]?.code);
}

// a template typed by an interface, as roblox-ts games usually declare their data
interface SavedStats {
	coins: number;
	level: number;
	inventory: string[];
}
const savedStats: SavedStats = { coins: 0, level: 1, inventory: [] };
const statsData = Geode.players({ name: "Stats", template: savedStats });
const guildTemplate: SavedStats = { coins: 0, level: 1, inventory: [] };
Geode.Shared.store({ name: "GuildStats", template: guildTemplate });
print(statsData.store);

// the receipt callback is what ProcessReceipt takes, and its handlers see Geode's receipt info
const marketplace = game.GetService("MarketplaceService");
marketplace.ProcessReceipt = Geode.receipts(playerData.store, {
	[123456]: (tx, info) => {
		tx.increment("coins", info.ProductId === 123456 ? 1000 : 0);
	},
});
const decide = Geode.receipts(
	playerData.store,
	{},
	{ decisions: { granted: "granted", notProcessed: "later" } },
);
const decision: string = decide({ PlayerId: 1, ProductId: 2, PurchaseId: "3" });
print(decision);

// a universe on any clock, here one that follows real time
const wallClock: Geode.Clock = {
	now: () => os.time(),
	wait: (seconds) => {
		task.wait(seconds);
	},
	spawn: (callback) => {
		task.spawn(callback);
	},
	delay: (seconds, callback) => {
		task.delay(seconds, callback);
	},
	resume: (thread) => {
		task.spawn(thread);
	},
};
const liveUniverse = Geode.Testing.universe({ clock: wallClock });
const liveClock: Geode.Clock = liveUniverse.clock;
print(liveClock.now(), liveUniverse.server().jobId);
const mockUniverse: Geode.Universe = Geode.Testing.universe({ clock: Geode.Testing.clock(100) });
mockUniverse.clock.advance(5);
