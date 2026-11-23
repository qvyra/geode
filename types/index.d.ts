/**
 * Typings for Geode, a layered data framework for Roblox. They mirror the Luau API: module
 * functions take `this: void`, methods are called with `:` and Luau `nil` is `undefined`.
 * Roblox types come from @rbxts/types
 *
 * Every type lives on the Geode namespace, so code can name them: `Geode.Profile`,
 * `Geode.ProfileStore`, `Geode.TxResult` and the rest
 */

declare namespace Geode {
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

	// Typed paths. Stores, profiles, transactions and the client take the data's type as `T`.
	// Without one, `T` is `object` and every path and value is as loose as `Path` and `unknown`.
	// With one, paths are lists checked against `T` and reads and writes take its types

	/** Values a path stops at: everything that isn't a plain table */
	type PathLeaf =
		| string
		| number
		| boolean
		| Vector3
		| Vector2
		| CFrame
		| Color3
		| UDim
		| UDim2
		| BrickColor
		| DateTime
		| EnumItem
		| NumberRange
		| NumberSequence
		| ColorSequence
		| Rect;

	/** One step down from the 8 segments a typed path spells out */
	type PathDepth = [never, 0, 1, 2, 3, 4, 5, 6, 7];

	/** One key's paths: the key itself, and the paths under it when its value is a table */
	type PathSegments<V, K extends string | number, D extends number> =
		| readonly [K]
		| (NonNullable<V> extends PathLeaf
				? never
				: readonly [K, ...PathOf<NonNullable<V>, PathDepth[D]>]);

	/**
	 * Every list path into `T`. A key of a record keyed by string is a `string` segment and an
	 * item of a list is a `number` segment, its 1-based index. Past 8 segments any tail is let
	 * through, and `ValueAt` still checks it
	 */
	type PathOf<T, D extends number = 8> = [D] extends [never]
		? readonly (string | number)[]
		: T extends PathLeaf
			? never
			: T extends readonly (infer E)[]
				? PathSegments<E, number, D>
				: T extends object
					? string extends keyof T
						? PathSegments<T[string & keyof T], string, D>
						: { [K in keyof T & string]-?: PathSegments<T[K], K, D> }[keyof T & string]
					: never;

	/** The value one segment down. A record's entry and a list's item may be missing */
	type PathChild<T, K> = T extends PathLeaf
		? never
		: T extends readonly (infer E)[]
			? K extends number
				? E | undefined
				: never
			: K extends keyof T
				? string extends keyof T
					? T[K] | undefined
					: T[K]
				: never;

	/** The type at a list path of `T`. `never` when the path leads nowhere */
	type ValueAt<T, P extends readonly unknown[]> = P extends readonly []
		? T
		: P extends readonly [infer Head, ...infer Rest]
			? PathChild<NonNullable<T>, Head> extends infer C
				? undefined extends C
					? Rest extends readonly []
						? C
						: ValueAt<NonNullable<C>, Rest> | undefined
					: ValueAt<C, Rest>
				: never
			: unknown;

	/**
	 * `unknown` when the value at `P` is a `V`, `never` otherwise or when `P` leads nowhere. A
	 * parameter typed `P & PathTo<T, P, V>` takes only paths to a `V`
	 */
	type PathTo<T, P extends readonly unknown[], V> = [ValueAt<T, P>] extends [never]
		? never
		: NonNullable<ValueAt<T, P>> extends V
			? unknown
			: never;

	/** A value as reads hand it out: frozen all the way down */
	type Frozen<T> = T extends PathLeaf
		? T
		: T extends object
			? { readonly [K in keyof T]: Frozen<T[K]> }
			: T;

	/** Whether `T` is the default, untyped data */
	type IsUntyped<T> = [object] extends [T] ? true : false;
	/** The paths a method takes for data of type `T` */
	type PathFor<T> = IsUntyped<T> extends true ? Path : PathOf<T>;
	/** What a read at `P` returns */
	type ReadAt<T, P> =
		IsUntyped<T> extends true
			? unknown
			: P extends readonly unknown[]
				? Frozen<ValueAt<T, P>>
				: Frozen<T>;
	/** What a write at `P` takes */
	type WriteAt<T, P> =
		IsUntyped<T> extends true ? unknown : P extends readonly unknown[] ? ValueAt<T, P> : T;
	/** A path that has to lead to a `V`, or any path for untyped data */
	type PathToFor<T, P, V> =
		IsUntyped<T> extends true ? unknown : P extends readonly unknown[] ? PathTo<T, P, V> : never;
	/** What one item of the list at `P` is */
	type ItemAt<T, P> =
		IsUntyped<T> extends true
			? unknown
			: P extends readonly unknown[]
				? NonNullable<ValueAt<T, P>> extends readonly (infer E)[]
					? E
					: never
				: never;
	/** The fields `merge` takes at `P`, the root when `P` is undefined */
	type MergeAt<T, P> =
		IsUntyped<T> extends true
			? Record<string, unknown>
			: Partial<NonNullable<P extends readonly unknown[] ? ValueAt<T, P> : T>>;

	type SourceKind =
		"system" | "reaction" | "bundle" | "player" | "plugin" | "mailbox" | "migration";

	interface Source {
		kind: SourceKind;
		userId?: number;
	}

	type SourceLike = SourceKind | Source;

	interface TransactOptions {
		source?: SourceLike;
		note?: string;
		/**
		 * Run everything, commit nothing, and report what guards found. Profiles and documents
		 * only: shared stores refuse it
		 */
		dryRun?: boolean;
	}

	interface DryRun {
		/** The paths the transaction would change */
		paths: string[];
		/** What stages found, such as every guard violation */
		findings: unknown[];
	}

	type TxErrorKind =
		"opFailed" | "unknownOp" | "invalidArgs" | "error" | "readOnly" | "busy" | "rejected";

	interface TxError {
		kind: TxErrorKind;
		message: string;
		/** The guard that rejected the transaction, when a guard did */
		guard?: string;
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

	type TxResult =
		{ ok: true; record?: CommitRecord; dryRun?: DryRun } | { ok: false; error: TxError };

	interface Outcome {
		committed: boolean;
		record?: CommitRecord;
		error?: TxError;
	}

	interface Transaction<T extends object = object> {
		readonly source: Source;
		get<const P extends PathFor<T> | undefined = undefined>(path?: P): ReadAt<T, P>;
		getBefore<const P extends PathFor<T> | undefined = undefined>(path?: P): ReadAt<T, P>;
		set<const P extends PathFor<T>>(path: P, value: WriteAt<T, P>): void;
		update<const P extends PathFor<T>>(
			path: P,
			transform: (current: ReadAt<T, P>) => WriteAt<T, P>,
		): void;
		increment<const P extends PathFor<T>>(path: P & PathToFor<T, P, number>, amount?: number): void;
		decrement<const P extends PathFor<T>>(path: P & PathToFor<T, P, number>, amount?: number): void;
		append<const P extends PathFor<T>>(
			path: P & PathToFor<T, P, readonly unknown[]>,
			value: ItemAt<T, P>,
		): void;
		insert<const P extends PathFor<T>>(
			path: P & PathToFor<T, P, readonly unknown[]>,
			index: number,
			value: ItemAt<T, P>,
		): void;
		remove(path: PathFor<T>): void;
		clear(path?: PathFor<T>): void;
		merge<const P extends PathFor<T> | undefined>(path: P, partial: MergeAt<T, P>): void;
		op(name: string, ...args: unknown[]): void;
		defer(callback: (outcome: Outcome) => void): void;
		/** Leaf changes the draft holds so far */
		diff(): DiffEntry[];
		/** Records who wrote a path, keyed by its formatted form. The first writer wins */
		markWriter(pathKey: string, kind: SourceKind): void;
		/** Who wrote a path in this transaction, the transaction's source when nobody claimed it */
		writerOf(pathKey: string): SourceKind;
	}

	type Observer<V = unknown> = (newValue: V, oldValue: V, record: CommitRecord) => void;

	/** Reads and the single op shorthands every data holder shares */
	interface Writable<T extends object = object> {
		get<const P extends PathFor<T> | undefined = undefined>(path?: P): ReadAt<T, P>;
		snapshot(): ReadAt<T, undefined>;
		transact(body: (tx: Transaction<T>) => void, options?: TransactOptions): TxResult;
		set<const P extends PathFor<T>>(path: P, value: WriteAt<T, P>): TxResult;
		update<const P extends PathFor<T>>(
			path: P,
			transform: (current: ReadAt<T, P>) => WriteAt<T, P>,
		): TxResult;
		increment<const P extends PathFor<T>>(
			path: P & PathToFor<T, P, number>,
			amount?: number,
		): TxResult;
		decrement<const P extends PathFor<T>>(
			path: P & PathToFor<T, P, number>,
			amount?: number,
		): TxResult;
		append<const P extends PathFor<T>>(
			path: P & PathToFor<T, P, readonly unknown[]>,
			value: ItemAt<T, P>,
		): TxResult;
		insert<const P extends PathFor<T>>(
			path: P & PathToFor<T, P, readonly unknown[]>,
			index: number,
			value: ItemAt<T, P>,
		): TxResult;
		remove(path: PathFor<T>): TxResult;
		clear(path?: PathFor<T>): TxResult;
		merge<const P extends PathFor<T> | undefined>(path: P, partial: MergeAt<T, P>): TxResult;
		op(name: string, ...args: unknown[]): TxResult;
		observe<const P extends PathFor<T>>(path: P, callback: Observer<ReadAt<T, P>>): Connection;
	}

	interface Document extends Writable {
		revision(): number;
		onCommit(callback: (record: CommitRecord) => void): Connection;
		setReadOnly(reason: string): void;
		clearReadOnly(): void;
		isReadOnly(): boolean;
		addStage(stage: (tx: Transaction) => void): void;
		addDerived(name: string, deps: Path[], read: (root: unknown) => unknown): void;
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

	type SchemaKind =
		| "string"
		| "number"
		| "boolean"
		| "literal"
		| "enum"
		| "array"
		| "map"
		| "struct"
		| "optional"
		| "union"
		| "codec"
		| "json";

	/** A schema node built with Geode.t. Its other fields are internal */
	interface Schema {
		readonly kind: SchemaKind;
	}

	/** How a value is stored and read back, for Geode.t.fromCodec */
	interface Codec {
		name: string;
		version: number;
		is: (value: unknown) => boolean;
		encode: (value: unknown) => unknown;
		/** false and a reason when the stored form is malformed */
		decode: (encoded: unknown) => LuaTuple<[boolean, unknown]>;
	}

	type IssueCode =
		| "type"
		| "nan"
		| "infinite"
		| "range"
		| "integer"
		| "length"
		| "pattern"
		| "literal"
		| "enum"
		| "sparse"
		| "mixed"
		| "key"
		| "extra"
		| "entries"
		| "union"
		| "codec"
		| "cycle"
		| "utf8"
		| "datatype"
		| "instance"
		| "function"
		| "thread";

	interface Issue {
		path: string;
		code: IssueCode;
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
		/** A name per argument, by index, for development tools to show. Needs `args` and may name fewer */
		names?: string[];
		/** What the op does, for development tools to show */
		description?: string;
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
		fromCodec(this: void, codec: Codec): Schema;
		isSchema(this: void, value: unknown): value is Schema;
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
		validate(
			this: void,
			schema: Schema,
			value: unknown,
			options?: ValidateOptions,
		): ValidationResult;
		encode(this: void, schema: Schema, value: unknown): unknown;
		decode(
			this: void,
			schema: Schema,
			encoded: unknown,
			options?: ValidateOptions,
		): LuaTuple<[true, unknown] | [false, ValidationResult]>;
		measure(this: void, json: { encode(value: unknown): string }, value: unknown): number;
		checkSize(
			this: void,
			json: { encode(value: unknown): string },
			value: unknown,
			budget: SizeBudget,
		): { size: number; level: "ok" | "soft" | "hard" };
		checkStorable(this: void, value: unknown, root?: string, limit?: number): ValidationResult;
	}

	// Guards

	type ActionName = "warn" | "flag" | "reject" | "rollback" | "kick";

	type GuardKind =
		"schema" | "range" | "delta" | "rate" | "rateValue" | "requires" | "subset" | "custom";

	interface Violation {
		guard: string;
		kind: GuardKind;
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
		/** What a player this guard kicks reads. Defaults to the store's `kickMessage` */
		kickMessage?: string;
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

	/** A rule built with Geode.guard. Its other fields are internal */
	interface Guard {
		readonly kind: GuardKind;
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
		/** The pipeline stage that checks every guard, for documents put together by hand */
		stage(): (tx: Transaction) => void;
	}

	// Facets

	/** Built with Geode.bundle, Geode.react and Geode.derive. Their other fields are internal */
	interface Bundle {
		readonly kind: "bundle";
		readonly name: string;
		readonly fields: readonly unknown[];
	}
	interface Reaction {
		readonly kind: "reaction";
		readonly name: string;
		readonly deps: readonly unknown[];
	}
	interface Derived {
		readonly kind: "derived";
		readonly name: string;
	}

	interface FacetSet {
		/** Reactions in the order they run */
		readonly order: readonly Reaction[];
		attach(document: Document): void;
		/** The pipeline stage that runs bundles and reactions, for documents put together by hand */
		stage(): (tx: Transaction) => void;
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
		/** Encode only, for size estimates */
		readonly json: { encode(value: unknown): string };
		dataStore(this: void, name: string, scope?: string): DataStoreAdapter;
		orderedDataStore(this: void, name: string, scope?: string): OrderedDataStoreAdapter;
		hashMap(this: void, name: string): HashMapAdapter;
		sortedMap(this: void, name: string): SortedMapAdapter;
		queue(this: void, name: string, invisibilityTimeout?: number): QueueAdapter;
		readonly messaging: MessagingAdapter;
		readonly teleport: TeleportAdapter;
		/** The server end of a remote event, made on first use */
		remote(this: void, name: string): ServerRemote;
		/** Where Studio tools reach a running game. Studio only */
		readonly bridge: ToolingBridge;
		/** Missing from services built by hand. Only the leaderstats option needs it */
		readonly leaderstats?: LeaderstatsAdapter;
	}

	interface KeyInfo {
		version: string;
		/** Milliseconds since the Unix epoch, like DataStoreKeyInfo */
		createdTime: number;
		updatedTime: number;
		userIds: number[];
		metadata: Record<string, unknown>;
	}

	interface WriteOptions {
		userIds?: number[];
		metadata?: Record<string, unknown>;
	}

	interface DataStoreAdapter {
		readonly name: string;
		readonly scope: string;
		/** `useCache = false` skips this server's cached copy of the key and asks the backend */
		get(key: string, options?: { useCache?: boolean }): Result<{ value: unknown; info?: KeyInfo }>;
		set(key: string, value: unknown, options?: WriteOptions): Result<string>;
		/** Returning undefined cancels the write. The transform may run more than once */
		update(
			key: string,
			transform: (current: unknown, info?: KeyInfo) => LuaTuple<[unknown, WriteOptions?]>,
		): Result<{ value: unknown; info?: KeyInfo; cancelled: boolean }>;
		remove(key: string): Result<{ value: unknown; info?: KeyInfo }>;
		increment(key: string, delta: number, options?: WriteOptions): Result<number>;
		listVersions(
			key: string,
			query?: { ascending?: boolean; minDate?: number; maxDate?: number; limit?: number },
		): Result<VersionInfo[]>;
		getVersion(key: string, version: string): Result<{ value: unknown; info?: KeyInfo }>;
	}

	interface OrderedDataStoreAdapter {
		readonly name: string;
		readonly scope: string;
		get(key: string): Result<number | undefined>;
		set(key: string, value: number): Result<undefined>;
		update(
			key: string,
			transform: (current: number | undefined) => number | undefined,
		): Result<{ value?: number; cancelled: boolean }>;
		remove(key: string): Result<number | undefined>;
		increment(key: string, delta: number): Result<number>;
		getSorted(query?: {
			ascending?: boolean;
			limit?: number;
			min?: number;
			max?: number;
		}): Result<{ key: string; value: number }[]>;
	}

	interface HashMapAdapter {
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
	}

	interface SortedMapAdapter {
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
	}

	interface QueueAdapter {
		readonly name: string;
		readonly invisibilityTimeout: number;
		add(value: unknown, ttl: number, priority?: number): Result<undefined>;
		read(options: {
			count: number;
			allOrNothing?: boolean;
			waitTimeout?: number;
		}): Result<{ items: unknown[]; id?: string }>;
		remove(id: string): Result<undefined>;
	}

	interface MessagingAdapter {
		publish(topic: string, data: unknown): Result<undefined>;
		subscribe(topic: string, handler: (data: unknown, sentAt: number) => void): Result<Connection>;
	}

	interface TeleportOptions {
		reservedServerCode?: string;
		data?: unknown;
	}

	interface TeleportAdapter {
		reserveServer(placeId: number): Result<{ code: string; serverId: string }>;
		/** Players are Player instances in a game and plain values on mock servers */
		teleport(placeId: number, players: unknown[], options?: TeleportOptions): Result<undefined>;
	}

	interface ServerRemote {
		fire(userId: number, ...args: unknown[]): void;
		onEvent(handler: (userId: number, ...args: unknown[]) => void): Connection;
	}

	interface BridgeConnection {
		publish(message: unknown): void;
		close(): void;
	}

	interface ToolingBridge {
		isAvailable(): boolean;
		/** Both sides cross a Bindable, so plain data only */
		open(
			attributes: Record<string, string | number>,
			handler: (request: unknown) => unknown,
		): BridgeConnection;
	}

	interface ClientServices {
		readonly userId: number;
		readonly clock: Clock;
		remote(
			this: void,
			name: string,
		): {
			fire(...args: unknown[]): void;
			onEvent(handler: (...args: unknown[]) => void): Connection;
		};
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
		stats(): { queued: number; inFlight: number; queuedByPriority: Record<string, number> };
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
		budgetPollInterval?: number;
		/** Returns a number in [0, 1), for backoff jitter. Tests pass a fixed sequence */
		random?: () => number;
	}

	// Profiles

	/**
	 * Where a store's data lives in Studio. `mock` keeps it in memory, `scope` uses real services
	 * apart from live servers, `real` uses live data, and `auto` picks `scope` when Studio has
	 * API access and `mock` when it doesn't
	 */
	type StudioMode = "mock" | "scope" | "real" | "auto";
	type StealPolicy = "steal" | "wait" | "fail";
	type SessionLostPolicy<T extends object = object> =
		"kick" | "none" | ((profile: Profile<T>, reason: string) => void);
	type ProfileState = "active" | "releasing" | "released" | "lost";
	/** Why a profile is being released, as `beforeRelease` hears it */
	type ReleaseReason = "leave" | "shutdown" | "handoff" | "release" | "destroy";
	/**
	 * The last transaction before a profile's final save. It must not yield: one that does fails,
	 * and so does one that errors or that a guard rejects. Each is reported and the release goes on
	 */
	type BeforeRelease<T extends object = object> = (
		tx: Transaction<T>,
		profile: Profile<T>,
		reason: ReleaseReason,
	) => void;

	type SaveResult =
		| { ok: true }
		| { ok: false; error: { kind: "adapter" | "lost" | "tooLarge" | "closed"; message: string } };

	interface Profile<T extends object = object> extends Writable<T> {
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
		/** `reason` is what the store's `beforeRelease` hears, "release" by default */
		release(reason?: ReleaseReason): SaveResult;
		wipe(): TxResult;
		hasReceipt(purchaseId: string): boolean;
		recordReceipt(purchaseId: string): void;
		onCommit(callback: (record: CommitRecord) => void): Connection;
	}

	/** Removes keys the template no longer has on load, after archiving them */
	interface PruneOptions {
		/** Paths that stay though the template doesn't have them, with everything under them */
		keep?: Path[];
		/** A whole number from 1 that goes up with every template change */
		version: number;
		/** Report what would go and remove nothing */
		dryRun?: boolean;
	}

	interface ProfileStoreOptions<T extends object = object> {
		name: string;
		/**
		 * A table of default values. Any object type fits, interfaces included. Give the store a
		 * type, like `Geode.Profile.store<Data>`, to check paths and values against it
		 */
		template: NoInfer<T>;
		services?: Services;
		scope?: string;
		scheduler?: Scheduler;
		schema?: Schema;
		schemaVersion?: number;
		migrations?: Record<number, (tx: Transaction) => void>;
		userKey?: (userId: number) => string;
		receiptHistory?: number;
		guards?: Guard[];
		/** What a player kicked by a guard reads, unless the guard has its own `kickMessage` */
		kickMessage?: string;
		bundles?: Bundle[];
		reactions?: Reaction[];
		derived?: Derived[];
		maxReactionDepth?: number;
		ops?: string[];
		autosaveInterval?: number;
		leaseTimeout?: number;
		stealAfter?: number;
		stealPolicy?: StealPolicy;
		onSessionLost?: SessionLostPolicy<T>;
		/** Runs once per profile before its final save, unless the session was lost first */
		beforeRelease?: BeforeRelease<T>;
		studio?: StudioMode;
		sizeBudget?: SizeBudget;
		closeTimeout?: number;
		loadTimeout?: number;
		bindToClose?: boolean;
		handoff?: boolean;
		mailbox?: boolean;
		audit?: boolean;
		/** Off by default. The removed keys go to a `<name>_pruned` DataStore first */
		prune?: PruneOptions;
		reportError?: (message: string) => void;
	}

	type LoadErrorKind =
		| "leaseHeld"
		| "adapter"
		| "corrupt"
		| "invalidData"
		| "alreadyLoaded"
		| "newerData"
		| "migrationFailed"
		| "destroyed";

	type LoadResult<T extends object = object> =
		| { ok: true; profile: Profile<T>; erasedAt?: number }
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

	interface ProfileStore<T extends object = object> {
		readonly name: string;
		readonly scope: string;
		readonly guardBroken: Signal<[violation: Violation, profile: Profile<T>]>;
		readonly erasedProfileLoaded: Signal<[key: string, erasedAt: number]>;
		load(key: string, options?: { userId?: number; userIds?: number[] }): LoadResult<T>;
		get(key: string): Profile<T> | undefined;
		openCount(): number;
		openKeys(): string[];
		inspect(key: string): ProfileInspection | undefined;
		/** `reason` is what `beforeRelease` hears, "shutdown" by default */
		releaseAll(reason?: ReleaseReason): number;
		/** Releases every profile with the reason "destroy", then refuses loads. Yields */
		destroy(): number;
		keyForUser(userId: number): string;
		/**
		 * Queues an op for the profile's next load. Fails with `invalidValue` unless the store was
		 * made with `mailbox = true`, and when the op can't be mailed or its arguments can't be
		 * stored. The value is the mail's sequence number
		 */
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
		[field: string]: unknown;
	}

	type ReceiptHandler = (tx: Transaction, info: ReceiptInfo) => void;

	/**
	 * What the ProcessReceipt callback returns: `granted` once a purchase is granted and saved,
	 * `notProcessed` to have Roblox ask again later. Defaults to `Enum.ProductPurchaseDecision`
	 */
	interface Decisions<D = Enum.ProductPurchaseDecision> {
		granted: D;
		notProcessed: D;
	}

	type ErasableKind = "profile" | "shared" | "board";

	interface EraseReport {
		/** How many stores erased something */
		erased: number;
		failures: { store: string; kind: ErasableKind; message: string }[];
		/** One entry per store that held something for the player, in the order they were made */
		stores: { store: string; kind: ErasableKind; ok: boolean; message?: string }[];
	}

	// Player data

	type Visibility = "private" | "owner" | "public";

	/** One value in every player's leaderstats folder, kept in step with the data */
	interface Leaderstat<T extends object = object> {
		path: PathFor<T>;
		name: string;
		/** Lowest first. Stats without one come after, in the order listed */
		order?: number;
		/** The text to show. A stat with a format is a StringValue */
		format?: (value: unknown) => string;
	}

	type LeaderstatKind = "IntValue" | "NumberValue" | "StringValue";

	/** Makes the values Roblox's player list shows. Live services make real ones */
	interface LeaderstatsAdapter {
		attach(
			player: unknown,
			stats: { name: string; kind: LeaderstatKind }[],
		): {
			set(name: string, value: number | string): void;
			/** Removes the values attach made, and a folder it made once nothing else is in it */
			destroy(): void;
			/**
			 * Stats left out because the folder already holds something of another class by
			 * their name. A value of the same class is written to instead. Neither is destroyed
			 */
			skipped?: { name: string; kind: LeaderstatKind; found: string }[];
		};
	}

	interface PlayerDataOptions<T extends object = object> extends ProfileStoreOptions<T> {
		products?: Record<number, (tx: Transaction<T>, info: ReceiptInfo) => void>;
		/**
		 * An IntValue, NumberValue or StringValue per stat, picked from the template's value at
		 * the path, or a StringValue with `format`
		 */
		leaderstats?: Leaderstat<T>[];
		replicate?: Record<string, Visibility>;
		loadRetries?: number;
		/** Geode sets ProcessReceipt itself, so any values do here; tests pass their own */
		decisions?: Decisions<unknown>;
	}

	interface PlayerProfile<T extends object = object> extends Writable<T> {
		readonly userId: number;
		readonly player: Player;
		isLoaded(): boolean;
		profile(): Profile<T> | undefined;
	}

	interface PlayerData<T extends object = object> {
		readonly store: ProfileStore<T>;
		readonly loaded: Signal<[player: Player, profile: Profile<T>]>;
		readonly released: Signal<[player: Player, profile: Profile<T>]>;
		onLoaded(callback: (player: Player, profile: Profile<T>) => void): Connection;
		onReleased(callback: (player: Player, profile: Profile<T>) => void): Connection;
		get(player: Player): PlayerProfile<T> | undefined;
		isLoaded(player: Player): boolean;
		waitFor(player: Player, timeout?: number): Profile<T> | undefined;
		destroy(): void;
	}

	interface SetupOptions {
		services?: Services;
		/** Every store's Studio mode. Without one, every store uses `mock` in Studio */
		studio?: StudioMode;
		/** The scope profile stores, shared stores and boards use unless given their own */
		scope?: string;
		reportError?: (message: string) => void;
		/** Let Studio development tools read the running game. On by default, Studio only */
		studioBridge?: boolean;
	}

	// Shared stores

	interface SharedStoreOptions {
		name: string;
		/** A table of default values. Any object type fits, interfaces included */
		template: object;
		services?: Services;
		scope?: string;
		/** Geode.setup's mode, or `mock` */
		studio?: StudioMode;
		scheduler?: Scheduler;
		schema?: Schema;
		schemaVersion?: number;
		guards?: Guard[];
		/** What a player kicked by a guard reads, unless the guard has its own `kickMessage` */
		kickMessage?: string;
		bundles?: Bundle[];
		reactions?: Reaction[];
		derived?: Derived[];
		maxReactionDepth?: number;
		ops?: string[];
		cacheTtl?: number;
		invalidate?: boolean;
		sizeBudget?: SizeBudget;
		/** The key that holds a player's data, or undefined when there's none. Opts in to `Geode.erase` */
		keyForUser?: (userId: number) => string | undefined;
		reportError?: (message: string) => void;
	}

	type WriteResult =
		| { ok: true; record?: CommitRecord }
		| {
				ok: false;
				error: {
					kind: TxErrorKind | "adapter" | "corrupt" | "tooLarge";
					message: string;
					guard?: string;
				};
		  };

	interface SharedStore {
		readonly name: string;
		readonly scope: string;
		get(key: string, path?: Path): Result<unknown>;
		observe(key: string, path: Path, callback: Observer): Connection;
		invalidate(key: string): void;
		/** RemoveAsync on the key. This server's copy goes back to the template and others read it again */
		delete(key: string): Result<undefined>;
		/** Shared stores don't do dry runs */
		transact(
			key: string,
			body: (tx: Transaction) => void,
			options?: Omit<TransactOptions, "dryRun">,
		): WriteResult;
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
		/** Geode.setup's mode, or `mock` */
		studio?: StudioMode;
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
		/** Geode.setup's mode, or `mock` */
		studio?: StudioMode;
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
		/** Geode.setup's mode, or `mock` */
		studio?: StudioMode;
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
		/** Geode.setup's mode, or `mock` */
		studio?: StudioMode;
		/** Geode.setup's scope, or `global` */
		scope?: string;
	}

	interface WindowedOptions extends LeaderboardOptions {
		window: "daily" | "weekly" | number;
		grace?: number;
	}

	interface Leaderboard {
		readonly name: string;
		readonly scope: string;
		submit(userId: number, score: number, mode?: RankMode): Result<number>;
		/** Takes the player off an all-time board, or off every window a windowed board still keeps */
		remove(userId: number): Result<undefined>;
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

	/** What a client atom at `P` holds: undefined until the data arrives or when it isn't sent */
	type ClientAt<T, P> = IsUntyped<T> extends true ? unknown : ReadAt<T, P> | undefined;

	interface GeodeClient<T extends object = object> {
		readonly userId: number;
		isReady(): boolean;
		waitUntilReady(): void;
		resync(): void;
		atom<const P extends PathFor<T>>(path: P, userId?: number): Atom<ClientAt<T, P>>;
		computed<V>(compute: () => V): Atom<V>;
		observe<const P extends PathFor<T>>(
			path: P,
			callback: (newValue: ClientAt<T, P>, oldValue: ClientAt<T, P>) => void,
			userId?: number,
		): Connection;
		op(name: string, ...args: unknown[]): void;
		charm(charm: { atom: (initial: unknown) => unknown }): {
			atom: (this: void, path: PathFor<T>, userId?: number) => unknown;
		};
	}

	interface VeinSnapshot {
		v: number;
		idle: boolean;
		modules: { kind: string; name: string; details?: Record<string, unknown> }[];
		missing: string[];
	}

	interface MockClock extends Clock {
		/** Moves time forward, waking every sleeper that comes due on the way */
		advance(seconds: number): void;
		/** How many sleepers are waiting */
		pending(): number;
		/** Runs `fn` in a clock thread, jumping from one wake up to the next until it returns */
		run<T>(fn: () => T): T;
	}

	/** `fault` sets one of these, or is "throttle" */
	interface FaultSpec {
		code?: number;
		/** The DataStore write goes through and the error is still reported */
		landed?: number;
		latency?: number;
		/** Runs before the call, as if another server got there first */
		foreignWrite?: (current: unknown) => unknown;
		/** Also shows the caller's transform the stale value once, like an UpdateAsync retry */
		rerun?: boolean;
	}

	interface FaultRule {
		/** "dataStore", "orderedDataStore", "hashMap", "sortedMap", "queue", "messaging" or "teleport" */
		service?: string;
		store?: string;
		method?: string;
		key?: string;
		fault: "throttle" | FaultSpec;
		times?: number;
	}

	interface MockPlayer {
		UserId: number;
		Name: string;
	}

	/** The mock bridge plus controls for tests */
	interface MockBridge extends ToolingBridge {
		attributes(): Record<string, string | number> | undefined;
		request(request: unknown): unknown;
		messages(): unknown[];
	}

	/** One mock server: the services a store takes, plus controls for tests */
	interface MockServer extends Services {
		readonly tooling: MockBridge;
		readonly leaderstats: LeaderstatsAdapter;
		/** The same leaderstats, read the way the player list would show them */
		readonly playerList: LeaderstatsAdapter & {
			/** Each value in the player's leaderstats folder, in order. Undefined without a folder */
			read(
				player: unknown,
			): { name: string; kind: LeaderstatKind; value: number | string }[] | undefined;
			/** How many players have a leaderstats folder */
			count(): number;
		};
		/** The player must be on this server for messages to arrive */
		client(userId: number): ClientServices;
		inject(rule: FaultRule): void;
		/** Each matching call uses one, refilled at `refillPerSecond`. Unset budgets are unlimited */
		setBudget(budgetType: BudgetType, amount: number, refillPerSecond?: number): void;
		clearFaults(): void;
		/** Join handlers run in their own threads, advance the clock to let them finish */
		join(userId: number, name?: string): MockPlayer;
		leave(userId: number): void;
		purchase(info: unknown): unknown;
		/** Pending calls never return and subscribers stop hearing messages */
		crash(): void;
		isAlive(): boolean;
		/** Each bindToClose callback gets its own clock thread */
		shutdown(): void;
	}

	/** `C` is the clock it was made with: a `MockClock` unless another was passed */
	interface Universe<C extends Clock = MockClock> {
		readonly clock: C;
		readonly teleports: readonly {
			fromJobId: string;
			placeId: number;
			players: unknown[];
			options?: TeleportOptions;
		}[];
		readonly kicks: readonly { jobId: string; userId: number; reason: string }[];
		server(options?: { jobId?: string; placeId?: number; studio?: boolean }): MockServer;
	}

	interface Testing {
		/**
		 * A universe of mock servers that share DataStores, MemoryStores and topics. It runs on a
		 * new `MockClock` unless given a clock; any clock works, but only a mock one can be advanced
		 */
		universe<C extends Clock = MockClock>(
			this: void,
			options?: {
				clock?: C;
				messagingLatency?: number;
				/** Each server keeps a copy of the DataStore keys it touches, like GetAsync's cache */
				dataStoreCache?: { seconds: number; cancelledUpdates?: boolean };
				limits?: {
					keyLength?: number;
					nameLength?: number;
					/** Needs `measure` too */
					valueSize?: number;
					measure?: (value: unknown) => number;
					/** Needs `measure` */
					keyThroughput?: boolean;
				};
			},
		): Universe<C>;
		clock(this: void, start?: number): MockClock;
	}

	/** A profile or shared record the way it sits in its DataStore key */
	interface StoredRecord {
		data: unknown;
		meta: {
			format?: number;
			schemaVersion: number;
			revision: number;
			updatedAt?: number;
			lastSession?: { session: string; revision: number };
			[field: string]: unknown;
		};
	}

	/** The Geode table itself, what `import Geode from "@rbxts/geode"` gives */
	interface Api {
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
			/**
			 * For tools editing a stored record outside a running Geode: the new data, the revision one
			 * higher, an `external:` session in `meta.lastSession`, a new `meta.updatedAt`, and the
			 * rest of `meta` unchanged. Errors when `stored` isn't a Geode record. `now` is in Unix
			 * seconds and `id` must be fresh for every write
			 */
			externalWrite(
				this: void,
				stored: unknown,
				data: unknown,
				options: { now: number; id: string },
			): StoredRecord;
			/** The layout Geode writes into `meta.format`. Missing means 0.4.0 to 0.5.0 */
			readonly recordFormat: number;
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

		readonly Profile: {
			store<T extends object = object>(
				this: void,
				options: ProfileStoreOptions<T>,
			): ProfileStore<T>;
		};
		/** Assign the result to `MarketplaceService.ProcessReceipt` */
		receipts<D = Enum.ProductPurchaseDecision>(
			this: void,
			store: ProfileStore,
			handlers: Record<number, ReceiptHandler>,
			options?: {
				decisions?: Decisions<D>;
				reportError?: (message: string) => void;
			},
		): (info: ReceiptInfo | globalThis.ReceiptInfo) => D;
		erase(this: void, userId: number, services?: Services): EraseReport;

		players<T extends object = object>(this: void, options: PlayerDataOptions<T>): PlayerData<T>;
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

		replicator(
			this: void,
			services?: Services,
			reportError?: (message: string) => void,
		): Replicator;
		remoteOp(this: void, name: string, options: RemoteOpOptions): void;
		readonly Client: {
			start<T extends object = object>(this: void, services?: ClientServices): GeodeClient<T>;
		};
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
}

declare const Geode: Geode.Api;

export = Geode;
