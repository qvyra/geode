// Typed paths: a store given its data's type checks every path and value against it. Compiled
// by the check suite, never run

import Geode from "../types";

interface Item {
	id: string;
	level: number;
}

interface Data {
	coins: number;
	name: string;
	settings: { music: boolean; volume: number };
	inventory: Item[];
	pets: Record<string, { level: number; nickname?: string }>;
	spawn: Vector3;
	title?: string;
}

const template: Data = {
	coins: 0,
	name: "",
	settings: { music: true, volume: 1 },
	inventory: [],
	pets: {},
	spawn: new Vector3(),
};

const PlayerData = Geode.players<Data>({
	name: "TypedData",
	template,
	beforeRelease: (tx, profile, reason) => {
		tx.set(["name"], reason);
		print(profile.get(["coins"]) + 1);
	},
	products: {
		[1]: (tx) => {
			tx.increment(["coins"], 100);
		},
	},
});

const store = Geode.Profile.store<Data>({ name: "TypedStore", template });
const loaded = store.load("player_1");
if (loaded.ok) {
	const profile = loaded.profile;

	const coins: number = profile.get(["coins"]);
	const music: boolean = profile.get(["settings", "music"]);
	const level: number | undefined = profile.get(["pets", "rex", "level"]);
	const first: Item | undefined = profile.get(["inventory", 1]);
	const firstLevel: number | undefined = profile.get(["inventory", 1, "level"]);
	const title: string | undefined = profile.get(["title"]);
	const spawn: Vector3 = profile.get(["spawn"]);
	const all = profile.get();
	print(coins, music, level, first, firstLevel, title, spawn, all.settings.volume);

	// reads are frozen
	// @ts-expect-error a read can't be changed
	all.settings.volume = 2;

	profile.set(["coins"], 5);
	profile.set(["settings"], { music: false, volume: 0.5 });
	profile.increment(["coins"], 10);
	profile.decrement(["settings", "volume"]);
	profile.append(["inventory"], { id: "sword", level: 1 });
	profile.insert(["inventory"], 1, { id: "shield", level: 2 });
	profile.update(["coins"], (current) => current * 2);
	profile.merge(["settings"], { music: true });
	profile.merge(undefined, { coins: 1 });
	profile.remove(["pets", "rex"]);
	profile.clear(["inventory"]);
	profile.observe(["settings", "volume"], (now, before) => {
		print(now - before);
	});
	profile.transact((tx) => {
		tx.increment(["pets", "rex", "level"]);
		const volume: number = tx.get(["settings", "volume"]);
		tx.set(["settings", "volume"], volume / 2);
	});

	// @ts-expect-error no such key
	profile.get(["gems"]);
	// @ts-expect-error a typed store takes list paths
	profile.get("coins");
	// @ts-expect-error the value at coins is a number
	profile.set(["coins"], "lots");
	// @ts-expect-error name holds a string, not a number
	profile.increment(["name"]);
	// @ts-expect-error settings isn't a list
	profile.append(["settings"], 1);
	// @ts-expect-error an item has to be an Item
	profile.append(["inventory"], "sword");
	// @ts-expect-error a list item is found by number
	profile.get(["inventory", "first"]);
	// @ts-expect-error music is a boolean
	profile.merge(["settings"], { music: 1 });
}

const player = undefined as unknown as Player;
const live = PlayerData.get(player);
if (live) {
	const name: string = live.get(["name"]);
	print(name);
}
PlayerData.onLoaded((_, profile) => profile.increment(["coins"]));

// Untyped stores keep the loose paths they always had
const loose = Geode.Profile.store({ name: "Loose", template: { coins: 0 } });
const looseLoaded = loose.load("player_1");
if (looseLoaded.ok) {
	const anything: unknown = looseLoaded.profile.get("coins");
	looseLoaded.profile.set("anything.at.all", 1);
	looseLoaded.profile.increment(["coins"]);
	print(anything);
}

// The client takes the same type. Atoms read undefined until the data arrives
const client = Geode.Client.start<Data>();
const coinsAtom = client.atom(["coins"]);
const atCoins: number | undefined = coinsAtom.get();
client.observe(["settings", "music"], (now) => {
	print(now === true);
});
// @ts-expect-error no such key on the client either
client.atom(["gems"]);
print(atCoins, Geode.Client.start().atom("anything").get());

// Deep data: paths past eight segments still check their values
interface Deep {
	a: { b: { c: { d: { e: { f: { g: { h: { i: { j: number } } } } } } } } };
}
const deepTemplate: Deep = { a: { b: { c: { d: { e: { f: { g: { h: { i: { j: 0 } } } } } } } } } };
const deep = Geode.Profile.store<Deep>({ name: "Deep", template: deepTemplate }).load("k");
if (deep.ok) {
	const j: number = deep.profile.get(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]);
	deep.profile.increment(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]);
	print(j);
}

// Wide data: many keys with nested tables stay fast to check
interface Stat {
	value: number;
	best: number;
	history: { at: number; value: number }[];
}
interface Wide {
	s01: Stat;
	s02: Stat;
	s03: Stat;
	s04: Stat;
	s05: Stat;
	s06: Stat;
	s07: Stat;
	s08: Stat;
	s09: Stat;
	s10: Stat;
	s11: Stat;
	s12: Stat;
	s13: Stat;
	s14: Stat;
	s15: Stat;
	s16: Stat;
	s17: Stat;
	s18: Stat;
	s19: Stat;
	s20: Stat;
	s21: Stat;
	s22: Stat;
	s23: Stat;
	s24: Stat;
	s25: Stat;
	s26: Stat;
	s27: Stat;
	s28: Stat;
	s29: Stat;
	s30: Stat;
	s31: Stat;
	s32: Stat;
	s33: Stat;
	s34: Stat;
	s35: Stat;
	s36: Stat;
	s37: Stat;
	s38: Stat;
	s39: Stat;
	s40: Stat;
	s41: Stat;
	s42: Stat;
	s43: Stat;
	s44: Stat;
	s45: Stat;
	s46: Stat;
	s47: Stat;
	s48: Stat;
	s49: Stat;
	s50: Stat;
	s51: Stat;
	s52: Stat;
	s53: Stat;
	s54: Stat;
	s55: Stat;
	s56: Stat;
	s57: Stat;
	s58: Stat;
	s59: Stat;
	s60: Stat;
	s61: Stat;
	s62: Stat;
	s63: Stat;
	s64: Stat;
	groups: Record<string, Record<string, Stat>>;
}
const wide = Geode.Profile.store<Wide>({ name: "Wide", template: {} as Wide }).load("k");
if (wide.ok) {
	wide.profile.increment(["s64", "best"]);
	wide.profile.append(["s01", "history"], { at: 0, value: 1 });
	const nested: number | undefined = wide.profile.get(["groups", "a", "b", "history", 1, "value"]);
	// @ts-expect-error s65 isn't a key
	wide.profile.get(["s65"]);
	print(nested);
}
