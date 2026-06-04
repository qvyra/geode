/**
 * Layered data framework for Roblox. Typings grow alongside the Luau modules they describe
 */
interface Geode {
	/** Semantic version of the running Geode build */
	readonly version: string;
}

declare const Geode: Geode;

export = Geode;
