/**
 * Typings for Geode, a layered data framework for Roblox. They mirror the Luau API: module
 * functions take `this: void`, methods are called with `:` and Luau `nil` is `undefined`.
 * Roblox types come from @rbxts/types
 */

// Results and errors

type ErrorKind =
	| "throttled"
	| "notFound"
	| "tooLarge"
	| "invalidKey"
	| "invalidValue"
	| "noAccess"
	| "unavailable"
	| "internal"
	| "unknown";

interface AdapterError {
	kind: ErrorKind;
	code?: number;
	message: string;
}

type Result<T> = { ok: true; value: T } | { ok: false; error: AdapterError };

interface Connection {
	disconnect(): void;
}

interface Signal<A extends unknown[]> {
	connect(callback: (...args: A) => void): Connection;
}

// Paths, transactions and documents

type Path = string | (string | number)[];

type SourceKind = "system" | "reaction" | "bundle" | "player" | "plugin" | "mailbox" | "migration";

interface Source {
	kind: SourceKind;
	userId?: number;
}

type SourceLike = SourceKind | Source;

interface TransactOptions {
	source?: SourceLike;
	note?: string;
}

type TxErrorKind =
	"opFailed" | "unknownOp" | "invalidArgs" | "error" | "readOnly" | "busy" | "rejected";

interface TxError {
	kind: TxErrorKind;
	message: string;
}

interface DiffEntry {
	readonly path: readonly (string | number)[];
	readonly old: unknown;
	readonly new: unknown;
}

interface CommitRecord {
	readonly revision: number;
	readonly source: Source;
	readonly ops: readonly { name: string; args: unknown[] }[];
	readonly diff: Readonly<Record<string, DiffEntry>>;
	readonly timestamp: number;
	readonly note?: string;
}

type TxResult = { ok: true; record?: CommitRecord } | { ok: false; error: TxError };

interface Outcome {
	committed: boolean;
	record?: CommitRecord;
	error?: TxError;
}

interface Transaction {
	readonly source: Source;
	get(path?: Path): unknown;
	getBefore(path?: Path): unknown;
	set(path: Path, value: unknown): void;
	update(path: Path, transform: (current: unknown) => unknown): void;
	increment(path: Path, amount?: number): void;
	decrement(path: Path, amount?: number): void;
	append(path: Path, value: unknown): void;
	insert(path: Path, index: number, value: unknown): void;
	remove(path: Path): void;
	clear(path?: Path): void;
	merge(path: Path | undefined, partial: Record<string, unknown>): void;
	op(name: string, ...args: unknown[]): void;
	defer(callback: (outcome: Outcome) => void): void;
}

type Observer = (newValue: unknown, oldValue: unknown, record: CommitRecord) => void;

/** Reads and the single op shorthands every data holder shares */
interface Writable {
	get(path?: Path): unknown;
	snapshot(): unknown;
	transact(body: (tx: Transaction) => void, options?: TransactOptions): TxResult;
	set(path: Path, value: unknown): TxResult;
	update(path: Path, transform: (current: unknown) => unknown): TxResult;
	increment(path: Path, amount?: number): TxResult;
	decrement(path: Path, amount?: number): TxResult;
	append(path: Path, value: unknown): TxResult;
	insert(path: Path, index: number, value: unknown): TxResult;
	remove(path: Path): TxResult;
	clear(path?: Path): TxResult;
	merge(path: Path | undefined, partial: Record<string, unknown>): TxResult;
	op(name: string, ...args: unknown[]): TxResult;
	observe(path: Path, callback: Observer): Connection;
}

interface Document extends Writable {
	revision(): number;
	onCommit(callback: (record: CommitRecord) => void): Connection;
	setReadOnly(reason: string): void;
	clearReadOnly(): void;
	isReadOnly(): boolean;
	addStage(stage: (tx: Transaction) => void): void;
	runHeld(outcome?: Outcome): void;
}

interface DocumentOptions {
	data?: unknown;
	revision?: number;
	ops?: string[];
	stages?: ((tx: Transaction) => void)[];
	clock?: Clock;
	reportError?: (message: string) => void;
	holdDeferred?: boolean;
}

// Schemas and codecs

/** A schema node built with Geode.t. Its fields are internal */
interface Schema {
	readonly kind: string;
}

interface Issue {
	path: string;
	code: string;
	message: string;
}

interface ValidationResult {
	ok: boolean;
	issues: Issue[];
	/** More issues existed than the limit allowed */
	truncated: boolean;
}

interface ValidateOptions {
	root?: string;
	limit?: number;
}

interface NumberOptions {
	min?: number;
	max?: number;
	integer?: boolean;
}

interface LengthOptions {
	minLength?: number;
	maxLength?: number;
}

interface OpOptions {
	/** One schema per argument. A call with other arguments fails with `invalidArgs` before the handler runs */
	args?: Schema[];
}

interface SchemaBuilders {
	string(this: void, options?: LengthOptions & { pattern?: string }): Schema;
	number(this: void, options?: NumberOptions): Schema;
	integer(this: void, options?: NumberOptions): Schema;
	boolean(this: void): Schema;
	literal(this: void, value: string | number | boolean): Schema;
	enum(this: void, values: (string | number)[]): Schema;
	array(this: void, item: Schema, options?: LengthOptions): Schema;
	map(this: void, value: Schema, options?: { key?: Schema; maxEntries?: number }): Schema;
	/** Unknown keys are refused unless `extra` is set */
	struct(this: void, fields: Record<string, Schema>, options?: { extra?: boolean }): Schema;
	optional(this: void, inner: Schema): Schema;
	union(this: void, options: Schema[]): Schema;
	json(this: void): Schema;
	fromCodec(this: void, codec: unknown): Schema;
}

interface CodecSet {
	readonly Vector3: Schema;
	readonly Vector2: Schema;
	readonly CFrame: Schema;
	readonly Color3: Schema;
	readonly UDim2: Schema;
	readonly DateTime: Schema;
	readonly BrickColor: Schema;
	EnumItem(this: void, enumType: Enum): Schema;
	custom(
		this: void,
		encode: (value: unknown) => unknown,
		decode: (encoded: unknown) => unknown,
		options?: { name?: string; version?: number; is?: (value: unknown) => boolean },
	): Schema;
}

interface SizeBudget {
	soft?: number;
	hard?: number;
}

interface SchemaTools {
	validate(this: void, schema: Schema, value: unknown, options?: ValidateOptions): ValidationResult;
	encode(this: void, schema: Schema, value: unknown): unknown;
	decode(
		this: void,
		schema: Schema,
		encoded: unknown,
		options?: ValidateOptions,
	): LuaTuple<[boolean, unknown]>;
	measure(this: void, json: { encode(value: unknown): string }, value: unknown): number;
	checkSize(
		this: void,
		json: { encode(value: unknown): string },
		value: unknown,
		budget: SizeBudget,
	): { size: number; level: "ok" | "soft" | "hard" };
	checkStorable(this: void, value: unknown, root?: string): ValidationResult;
}

// Guards

type ActionName = "warn" | "flag" | "reject" | "rollback" | "kick";

interface Violation {
	guard: string;
	kind: string;
	path?: string;
	reason: string;
	action: ActionName;
	source: Source;
	userId?: number;
	ops: string[];
	timestamp: number;
	/** The value at `path` before the transaction, when the path can be read back */
	before?: unknown;
	/** The value at `path` after the transaction, when the path can be read back */
	after?: unknown;
}

type Action = ActionName | ((violation: Violation) => ActionName | undefined);

interface GuardOptions {
	name?: string;
	action?: Action;
	ops?: string[];
	skipSources?: SourceKind[];
}

interface GuardContext {
	source: Source;
	userId?: number;
	ops: { name: string; args: unknown[] }[];
	opNames: Record<string, boolean>;
	now: number;
	diff: DiffEntry[];
	/** The draft state that would be committed */
	state: unknown;
	get(this: void, path?: Path): unknown;
	getBefore(this: void, path?: Path): unknown;
}

/** A rule built with Geode.guard. Its fields are internal */
interface Guard {
	readonly name: string;
}

interface GuardBuilders {
	range(
		this: void,
		path: Path,
		bounds: { min?: number; max?: number },
		options?: GuardOptions,
	): Guard;
	delta(
		this: void,
		path: Path,
		limits: { max?: number; up?: number; down?: number },
		options?: GuardOptions,
	): Guard;
	rate(
		this: void,
		path: Path,
		limit: { count: number; window: number },
		options?: GuardOptions,
	): Guard;
	rateValue(
		this: void,
		path: Path,
		limit: { gain?: number; loss?: number; window: number },
		options?: GuardOptions,
	): Guard;
	requires(this: void, path: Path, other: Path, options?: GuardOptions): Guard;
	subset(this: void, path: Path, of: Path, options?: GuardOptions): Guard;
	schema(this: void, schema: Schema, options?: GuardOptions): Guard;
	custom(
		this: void,
		check: (
			diff: DiffEntry[],
			state: unknown,
			ctx: GuardContext,
		) => LuaTuple<[boolean, string?]> | boolean,
		options?: GuardOptions,
	): Guard;
}

interface GuardSet {
	readonly broken: Signal<[violation: Violation]>;
	add(guard: Guard): void;
	attach(document: Document): void;
}

// Facets

/** Built with Geode.bundle, Geode.react and Geode.derive. Their fields are internal */
interface Bundle {
	readonly fields: readonly unknown[];
}
interface Reaction {
	readonly deps: readonly unknown[];
}
interface Derived {
	readonly name: string;
}

interface FacetSet {
	attach(document: Document): void;
}

// Services and adapters

interface Clock {
	now(): number;
	wait(seconds: number): void;
	spawn(callback: () => void): void;
	delay(seconds: number, callback: () => void): void;
	/** Resumes a parked coroutine on the next step */
	resume(thread: thread): void;
}

type BudgetType =
	| "standardRead"
	| "standardWrite"
	| "standardList"
	| "standardRemove"
	| "orderedRead"
	| "orderedWrite"
	| "orderedList"
	| "orderedRemove";

/** Every Roblox service Geode uses, behind adapters. Live ones come from Geode.Raw.services() */
interface Services {
	readonly jobId: string;
	readonly placeId: number;
	guid(this: void): string;
	readonly clock: Clock;
	readonly budget: { get(budgetType: BudgetType): number };
	readonly players: {
		kick(userId: number, reason: string): Result<undefined>;
		onJoin(handler: (userId: number, player: Player) => void): Connection;
		onLeave(handler: (userId: number, player: Player) => void): Connection;
		list(): { userId: number; player: Player }[];
		isPresent(userId: number): boolean;
	};
	readonly marketplace: { setProcessReceipt(callback: (info: unknown) => unknown): void };
	readonly lifecycle: { bindToClose(callback: () => void): void; isStudio(): boolean };
}

interface ClientServices {
	readonly userId: number;
	readonly clock: Clock;
	remote(
		this: void,
		name: string,
	): { fire(...args: unknown[]): void; onEvent(handler: (...args: unknown[]) => void): Connection };
}

type Priority = "release" | "save" | "load" | "read" | "background";

interface Scheduler {
	submit<T>(request: {
		priority: Priority;
		run: () => Result<T>;
		key?: string;
		write?: boolean;
		budget?: BudgetType | BudgetType[];
		coalesce?: string;
		size?: number;
	}): Result<T>;
}

interface SchedulerOptions {
	clock: Clock;
	budget?: Services["budget"];
	maxConcurrent?: number;
	maxAttempts?: number;
	baseDelay?: number;
	maxDelay?: number;
	agingInterval?: number;
	writeSpacing?: number;
	keyThroughput?: boolean;
}

// Profiles

type StudioMode = "mock" | "scope" | "real";
type StealPolicy = "steal" | "wait" | "fail";
type SessionLostPolicy = "kick" | "none" | ((profile: Profile, reason: string) => void);
type ProfileState = "active" | "releasing" | "released" | "lost";

type SaveResult =
	| { ok: true }
	| { ok: false; error: { kind: "adapter" | "lost" | "tooLarge" | "closed"; message: string } };

interface Profile extends Writable {
	readonly key: string;
	readonly userId?: number;
	readonly released: Signal<[]>;
	readonly sessionLost: Signal<[reason: string]>;
	readonly saved: Signal<[revision: number]>;
	revision(): number;
	sessionId(): string;
	mailboxCursor(): number;
	state(): ProfileState;
	isActive(): boolean;
	isSaved(): boolean;
	save(): SaveResult;
	release(): SaveResult;
	wipe(): TxResult;
	hasReceipt(purchaseId: string): boolean;
	recordReceipt(purchaseId: string): void;
	onCommit(callback: (record: CommitRecord) => void): Connection;
}

interface ProfileStoreOptions {
	name: string;
	template: Record<string, unknown>;
	services?: Services;
	scope?: string;
	scheduler?: Scheduler;
	schema?: Schema;
	schemaVersion?: number;
	migrations?: Record<number, (tx: Transaction) => void>;
	userKey?: (userId: number) => string;
	receiptHistory?: number;
	guards?: Guard[];
	bundles?: Bundle[];
	reactions?: Reaction[];
	derived?: Derived[];
	maxReactionDepth?: number;
	ops?: string[];
	autosaveInterval?: number;
	leaseTimeout?: number;
	stealAfter?: number;
	stealPolicy?: StealPolicy;
	onSessionLost?: SessionLostPolicy;
	studio?: StudioMode;
	sizeBudget?: SizeBudget;
	closeTimeout?: number;
	loadTimeout?: number;
	bindToClose?: boolean;
	handoff?: boolean;
	audit?: boolean;
	reportError?: (message: string) => void;
}

type LoadErrorKind =
	| "leaseHeld"
	| "adapter"
	| "corrupt"
	| "invalidData"
	| "alreadyLoaded"
	| "newerData"
	| "migrationFailed";

type LoadResult =
	| { ok: true; profile: Profile; erasedAt?: number }
	| { ok: false; error: { kind: LoadErrorKind; message: string } };

interface VersionInfo {
	version: string;
	createdTime: number;
	deleted: boolean;
}

interface RollbackResult {
	ok: boolean;
	message?: string;
	via?: "here" | "holder" | "loaded";
}

interface AuditEntry {
	revision: number;
	source: SourceKind;
	userId?: number;
	note?: string;
	ops: string[];
	paths: string[];
	at: number;
}

interface AuditBatch {
	from: number;
	to: number;
	entries: AuditEntry[];
}

interface ProfileInspection {
	/** The data in stored form, the way it crosses a Bindable */
	data: unknown;
	/** Path to codec name for every codec value in `data` */
	codecs: Record<string, string>;
	revision: number;
	state: ProfileState;
	session: string;
}

interface ProfileStore {
	readonly name: string;
	readonly scope: string;
	readonly guardBroken: Signal<[violation: Violation, profile: Profile]>;
	readonly erasedProfileLoaded: Signal<[key: string, erasedAt: number]>;
	load(key: string, options?: { userId?: number; userIds?: number[] }): LoadResult;
	get(key: string): Profile | undefined;
	openCount(): number;
	openKeys(): string[];
	inspect(key: string): ProfileInspection | undefined;
	releaseAll(): number;
	keyForUser(userId: number): string;
	mail(key: string, op: string, ...args: unknown[]): Result<number>;
	erase(key: string): { ok: boolean; message?: string };
	history(key: string, options?: { ascending?: boolean; limit?: number }): Result<VersionInfo[]>;
	version(key: string, versionId: string): Result<unknown>;
	rollback(key: string, versionId: string, note?: string): RollbackResult;
	sendOp(key: string, name: string, ...args: unknown[]): boolean;
	auditLog(key: string, maxBatches?: number): Result<AuditBatch[]>;
}

interface ReceiptInfo {
	PlayerId: number;
	ProductId: number;
	PurchaseId: string | number;
}

type ReceiptHandler = (tx: Transaction, info: ReceiptInfo) => void;

interface EraseReport {
	erased: number;
	failures: { store: string; message: string }[];
}

// Player data

type Visibility = "private" | "owner" | "public";

interface PlayerDataOptions extends ProfileStoreOptions {
	products?: Record<number, ReceiptHandler>;
	replicate?: Record<string, Visibility>;
	loadRetries?: number;
	decisions?: { granted: unknown; notProcessed: unknown };
}

interface PlayerProfile extends Writable {
	readonly userId: number;
	readonly player: Player;
	isLoaded(): boolean;
	profile(): Profile | undefined;
}

interface PlayerData {
	readonly store: ProfileStore;
	readonly loaded: Signal<[player: Player, profile: Profile]>;
	readonly released: Signal<[player: Player, profile: Profile]>;
	onLoaded(callback: (player: Player, profile: Profile) => void): Connection;
	onReleased(callback: (player: Player, profile: Profile) => void): Connection;
	get(player: Player): PlayerProfile | undefined;
	isLoaded(player: Player): boolean;
	waitFor(player: Player, timeout?: number): Profile | undefined;
	destroy(): void;
}

interface SetupOptions {
	services?: Services;
	studio?: StudioMode;
	reportError?: (message: string) => void;
	/** Let Studio development tools read the running game. On by default, Studio only */
	studioBridge?: boolean;
}

// Shared stores

interface SharedStoreOptions {
	name: string;
	template: Record<string, unknown>;
	services?: Services;
	scope?: string;
	scheduler?: Scheduler;
	schema?: Schema;
	schemaVersion?: number;
	guards?: Guard[];
	bundles?: Bundle[];
	reactions?: Reaction[];
	derived?: Derived[];
	maxReactionDepth?: number;
	ops?: string[];
	cacheTtl?: number;
	invalidate?: boolean;
	sizeBudget?: SizeBudget;
	reportError?: (message: string) => void;
}

type WriteResult =
	| { ok: true; record?: CommitRecord }
	| {
			ok: false;
			error: { kind: TxErrorKind | "adapter" | "corrupt" | "tooLarge"; message: string };
	  };

interface SharedStore {
	readonly name: string;
	readonly scope: string;
	get(key: string, path?: Path): Result<unknown>;
	observe(key: string, path: Path, callback: Observer): Connection;
	invalidate(key: string): void;
	transact(key: string, body: (tx: Transaction) => void, options?: TransactOptions): WriteResult;
	set(key: string, path: Path, value: unknown): WriteResult;
	update(key: string, path: Path, transform: (current: unknown) => unknown): WriteResult;
	increment(key: string, path: Path, amount?: number): WriteResult;
	decrement(key: string, path: Path, amount?: number): WriteResult;
	append(key: string, path: Path, value: unknown): WriteResult;
	insert(key: string, path: Path, index: number, value: unknown): WriteResult;
	remove(key: string, path: Path): WriteResult;
	clear(key: string, path?: Path): WriteResult;
	merge(key: string, path: Path | undefined, partial: Record<string, unknown>): WriteResult;
	op(key: string, name: string, ...args: unknown[]): WriteResult;
}

// MemoryStore

type SortKey = string | number;

interface SortedEntry {
	key: string;
	value: unknown;
	sortKey?: SortKey;
}

interface SortedBound {
	key?: string;
	sortKey?: SortKey;
}

interface SortedRange {
	descending?: boolean;
	count: number;
	lower?: SortedBound;
	upper?: SortedBound;
}

interface EphemeralOptions {
	services?: Services;
	scheduler?: Scheduler;
	schema?: Schema;
}

interface EphemeralHashMap {
	readonly name: string;
	get(key: string): Result<unknown>;
	set(key: string, value: unknown, ttl: number): Result<undefined>;
	update(
		key: string,
		transform: (current: unknown) => unknown,
		ttl: number,
	): Result<{ value: unknown; cancelled: boolean }>;
	remove(key: string): Result<undefined>;
	list(limit?: number): Result<{ key: string; value: unknown }[]>;
	destroy(): void;
}

interface EphemeralSortedMap {
	readonly name: string;
	get(key: string): Result<SortedEntry | undefined>;
	set(key: string, value: unknown, ttl: number, sortKey?: SortKey): Result<undefined>;
	update(
		key: string,
		transform: (current: unknown, sortKey?: SortKey) => LuaTuple<[unknown, SortKey?]>,
		ttl: number,
	): Result<{ value: unknown; sortKey?: SortKey; cancelled: boolean }>;
	remove(key: string): Result<undefined>;
	getRange(range: SortedRange): Result<SortedEntry[]>;
	destroy(): void;
}

interface EphemeralQueue {
	readonly name: string;
	add(value: unknown, ttl: number, priority?: number): Result<undefined>;
	read(options: {
		count: number;
		allOrNothing?: boolean;
		waitTimeout?: number;
	}): Result<{ items: unknown[]; id?: string }>;
	remove(id: string): Result<undefined>;
	destroy(): void;
}

interface PremadeOptions {
	services?: Services;
	scheduler?: Scheduler;
}

interface Presence {
	readonly name: string;
	set(userId: number): Result<undefined>;
	clear(userId: number): Result<undefined>;
	where(userId: number): Result<{ jobId: string; placeId: number } | undefined>;
	trackedCount(): number;
	estimatedCost(): number;
	destroy(): void;
}

interface Lock {
	readonly token: number;
	renew(): boolean;
	release(): boolean;
	isHeld(): boolean;
}

interface Mutex {
	readonly name: string;
	acquire(key: string, wait?: number): Result<Lock | undefined>;
	estimatedCost(): number;
	destroy(): void;
}

interface Counter {
	readonly name: string;
	increment(key: string, delta?: number): Result<number>;
	get(key: string): Result<number>;
	estimatedCost(): number;
	destroy(): void;
}

interface RateLimiter {
	readonly name: string;
	allow(key: string, cost?: number): Result<boolean>;
	estimatedCost(): number;
	destroy(): void;
}

interface Claim {
	readonly jobs: unknown[];
	ack(): Result<undefined>;
	nack(): void;
}

interface JobQueue {
	readonly name: string;
	push(job: unknown, priority?: number): Result<undefined>;
	claim(count?: number, wait?: number): Result<Claim | undefined>;
	estimatedCost(): number;
	destroy(): void;
}

// Matchmaking and leaderboards

interface MatchmakerOptions {
	name: string;
	placeId: number;
	matchSize: number;
	mode?: string;
	region?: string;
	band?: { start?: number; widenPerSecond?: number; max?: number };
	ticketTtl?: number;
	tick?: number;
	lease?: number;
	elect?: boolean;
	onMatch?: (match: Match) => void;
	services?: Services;
	scheduler?: Scheduler;
	reportError?: (message: string) => void;
}

interface Ticket {
	id: string;
	players: number[];
	rating: number;
	createdAt: number;
	matchId?: string;
	reservedCode?: string;
	cancelled?: boolean;
}

interface Match {
	id: string;
	placeId: number;
	reservedCode: string;
	players: number[];
	tickets: string[];
}

interface Matchmaker {
	readonly name: string;
	readonly mode: string;
	readonly region: string;
	enqueue(players: number[], rating: number): Result<string>;
	cancel(ticketId: string): Result<boolean>;
	status(ticketId: string): Result<{ state: "waiting" | "matched" | "gone"; ticket?: Ticket }>;
	teleport(ticket: Ticket, players: Player[]): Result<undefined>;
	runOnce(): Match[];
	isMatcher(): boolean;
	start(): void;
	stop(): void;
	destroy(): void;
}

type RankMode = "max" | "min" | "sum" | "latest";

interface LeaderboardOptions {
	mode?: RankMode;
	cacheTtl?: number;
	services?: Services;
	scheduler?: Scheduler;
}

interface WindowedOptions extends LeaderboardOptions {
	window: "daily" | "weekly" | number;
	grace?: number;
}

interface Leaderboard {
	readonly name: string;
	submit(userId: number, score: number, mode?: RankMode): Result<number>;
	get(userId: number): Result<number | undefined>;
	top(count: number, windowIndex?: number): Result<readonly { userId: number; score: number }[]>;
	windowIndex(at?: number): number;
	destroy(): void;
}

// Replication and tooling

interface Replicator {
	track(owner: number, profile: Profile, visibility: Record<string, Visibility>): void;
	untrack(owner: number): void;
	destroy(): void;
}

interface RemoteOpOptions {
	store: ProfileStore;
	args?: Schema[];
	rateLimit?: { count: number; window: number; action?: "drop" | "kick" };
	services?: Services;
	reportError?: (message: string) => void;
}

interface Atom<T> {
	get(): T;
	subscribe(callback: (newValue: T, oldValue: T) => void): Connection;
}

interface GeodeClient {
	readonly userId: number;
	isReady(): boolean;
	waitUntilReady(): void;
	resync(): void;
	atom(path: Path, userId?: number): Atom<unknown>;
	computed<T>(compute: () => T): Atom<T>;
	observe(
		path: Path,
		callback: (newValue: unknown, oldValue: unknown) => void,
		userId?: number,
	): Connection;
	op(name: string, ...args: unknown[]): void;
	charm(charm: { atom: (initial: unknown) => unknown }): {
		atom: (this: void, path: Path, userId?: number) => unknown;
	};
}

interface VeinSnapshot {
	v: number;
	idle: boolean;
	modules: { kind: string; name: string; details?: Record<string, unknown> }[];
	missing: string[];
}

interface MockClock extends Clock {
	advance(seconds: number): void;
}

interface Testing {
	/** A universe of mock servers. See the Luau docs for its full shape */
	universe(
		this: void,
		options?: {
			clock?: MockClock;
			messagingLatency?: number;
			limits?: {
				keyLength?: number;
				nameLength?: number;
				valueSize?: number;
				keyThroughput?: boolean;
			};
		},
	): {
		readonly clock: MockClock;
		server(options?: { jobId?: string; placeId?: number; studio?: boolean }): Services;
	};
	clock(this: void, start?: number): MockClock;
}

interface Geode {
	/** Semantic version of the running Geode build */
	readonly version: string;

	readonly Raw: {
		services(this: void): Services;
		fromRoblox(this: void, roblox: unknown): Services;
		clock(this: void): Clock;
		scheduler(this: void, options: SchedulerOptions): Scheduler;
		classifyError(
			this: void,
			raw: unknown,
			service?: "dataStore" | "memoryStore" | "messaging",
		): AdapterError;
		document(this: void, options?: DocumentOptions): Document;
		guards(
			this: void,
			options?: {
				guards?: Guard[];
				clock?: Clock;
				players?: Services["players"];
				reportError?: (message: string) => void;
			},
		): GuardSet;
		facets(
			this: void,
			options: {
				bundles?: Bundle[];
				reactions?: Reaction[];
				derived?: Derived[];
				maxDepth?: number;
			},
		): FacetSet;
	};
	readonly Testing: Testing;

	readonly t: SchemaBuilders;
	readonly codec: CodecSet;
	readonly schema: SchemaTools;
	readonly guard: GuardBuilders;

	bundle(
		this: void,
		fields: Path[],
		normalize: (tx: Transaction) => void,
		options?: { name?: string },
	): Bundle;
	react(
		this: void,
		deps: Path[],
		run: (tx: Transaction) => void,
		options: { writes: Path[]; name?: string },
	): Reaction;
	derive(this: void, name: string, deps: Path[], compute: (state: unknown) => unknown): Derived;
	op(
		this: void,
		name: string,
		handler: (tx: Transaction, ...args: never[]) => void,
		options?: OpOptions,
	): void;

	readonly Profile: { store(this: void, options: ProfileStoreOptions): ProfileStore };
	receipts(
		this: void,
		store: ProfileStore,
		handlers: Record<number, ReceiptHandler>,
		options?: {
			decisions?: { granted: unknown; notProcessed: unknown };
			reportError?: (message: string) => void;
		},
	): (info: ReceiptInfo) => unknown;
	erase(this: void, userId: number, services?: Services): EraseReport;

	players(this: void, options: PlayerDataOptions): PlayerData;
	setup(this: void, options: SetupOptions): void;

	readonly Shared: { store(this: void, options: SharedStoreOptions): SharedStore };
	readonly Ephemeral: {
		hashMap(this: void, name: string, options?: EphemeralOptions): EphemeralHashMap;
		sortedMap(this: void, name: string, options?: EphemeralOptions): EphemeralSortedMap;
		queue(
			this: void,
			name: string,
			options?: EphemeralOptions & { invisibilityTimeout?: number },
		): EphemeralQueue;
	};
	readonly Presence: {
		new: (
			this: void,
			options?: PremadeOptions & { name?: string; ttl?: number; heartbeat?: number },
		) => Presence;
	};
	readonly Mutex: {
		new: (this: void, name: string, options?: PremadeOptions & { lease?: number }) => Mutex;
	};
	readonly Counter: {
		new: (this: void, name: string, options?: PremadeOptions & { ttl?: number }) => Counter;
	};
	readonly RateLimiter: {
		new: (
			this: void,
			name: string,
			options: PremadeOptions & { limit: number; window: number },
		) => RateLimiter;
	};
	readonly JobQueue: {
		new: (
			this: void,
			name: string,
			options?: PremadeOptions & { invisibilityTimeout?: number; ttl?: number },
		) => JobQueue;
	};
	readonly Matchmaker: { new: (this: void, options: MatchmakerOptions) => Matchmaker };
	readonly Ranked: {
		allTime(this: void, name: string, options?: LeaderboardOptions): Leaderboard;
		windowed(this: void, name: string, options: WindowedOptions): Leaderboard;
	};

	replicator(this: void, services?: Services, reportError?: (message: string) => void): Replicator;
	remoteOp(this: void, name: string, options: RemoteOpOptions): void;
	readonly Client: { start(this: void, services?: ClientServices): GeodeClient };
	readonly Vein: {
		readonly VERSION: number;
		snapshot(this: void): VeinSnapshot;
		setBridgeEnabled(this: void, on: boolean): void;
		subscribe(
			this: void,
			callback: (message: Readonly<Record<string, unknown>>) => void,
		): Connection;
	};
}

declare const Geode: Geode;

export = Geode;
