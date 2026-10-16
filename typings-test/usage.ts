// Compiled by the check suite, never run. If a change to the typings breaks normal usage, this
// file stops compiling

import Geode from "../types";

const playerData = Geode.players({
	name: "PlayerData",
	template: { coins: 0, xp: 0, level: 1, inventory: [] },
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

const handle = playerData.get(game.GetService("Players").GetPlayers()[0]);
if (handle?.isLoaded() === true) {
	handle.set("level", 2);
}

const guilds = Geode.Shared.store({
	name: "Guilds",
	template: { bank: 0 },
	guards: [Geode.guard.range("bank", { min: 0 })],
});
const deposit = guilds.increment("guild_1", "bank", 50);
if (!deposit.ok) {
	warn(deposit.error.message);
}

const schema = Geode.t.struct({ coins: Geode.t.integer({ min: 0 }), pos: Geode.codec.Vector3 });
const [decoded, value] = Geode.schema.decode(schema, {});
print(decoded, value);

const daily = Geode.Ranked.windowed("Daily", { window: "daily", mode: "max" });
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
	{ args: [Geode.t.string(), Geode.t.integer({ min: 1 })] },
);
Geode.remoteOp("buyItem", { store: playerData.store, args: [Geode.t.string()] });

const client = Geode.Client.start();
const coins = client.atom("coins");
coins.subscribe((newValue) => {
	print(newValue);
});
client.op("buyItem", "sword");

print(Geode.Vein.snapshot().idle);
