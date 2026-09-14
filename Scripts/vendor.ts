/** Reproduce patched source archives without modifying the build inputs. */
import { createHash } from "node:crypto";
import {
  closeSync,
  constants,
  cpSync,
  existsSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  renameSync,
  rmSync,
  writeFileSync,
  type Stats,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

export type Source = {
  name: string;
  version: string;
  destination: string;
  url: string;
  sha256: string;
  archiveRoot: string;
  paths: string[];
  patches: { name: string; file: string; description: string; upstream?: string }[];
  upstream: { repository: string; revision: string };
};

const repository = resolve(import.meta.dir, "..");
const recipeRoot = join(repository, "third-party/vendor");
export const vendorInputs = [
  "Vendor/FluidAudio",
  "third-party/vendor",
  "Scripts/vendor.ts",
  "Scripts/vendor-session.ts",
  "Scripts/vendor.test.ts",
  "Scripts/vendor-LICENSE",
  "package.json",
  "bun.lock",
  "bunfig.toml",
  "tsconfig.json",
  "mise.toml",
  "mise.lock",
  "lefthook.yml",
];
export const hash = (bytes: Uint8Array) =>
  createHash("sha256").update(bytes).digest("hex");
export const id = (source: Source) => `${source.name}-${source.version}`;
export const sourceDirectory = (root: string, source: Source) =>
  resolve(root, source.destination);

const safeRelative = (value: unknown) =>
  typeof value === "string" &&
  value.length > 0 &&
  !value.startsWith("/") &&
  value.split("/").every((part) => part && part !== "." && part !== "..");
const safeDestination = (value: unknown) =>
  safeRelative(value) ||
  (typeof value === "string" &&
    /^\.\.\/\.\.\/Vendor\/[a-zA-Z0-9_.-]+$/.test(value));

export function readSources(file: string): Source[] {
  const data = JSON.parse(readFileSync(file, "utf8"));
  if (data?.schema !== 2 || !Array.isArray(data.sources)) {
    throw new Error("invalid vendor manifest");
  }
  const names = new Set<string>();
  const destinations = new Set<string>();
  const patchFiles = new Set<string>();
  for (const source of data.sources) {
    if (
      !source ||
      typeof source.name !== "string" ||
      !/^[a-zA-Z0-9_-]+$/.test(source.name) ||
      typeof source.version !== "string" ||
      !/^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$/.test(source.version) ||
      !safeDestination(source.destination) ||
      typeof source.sha256 !== "string" ||
      !/^[0-9a-f]{64}$/.test(source.sha256) ||
      !source.upstream ||
      typeof source.upstream.repository !== "string" ||
      !/^https:\/\/github\.com\/[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+$/.test(
        source.upstream.repository,
      ) ||
      typeof source.upstream.revision !== "string" ||
      !/^[0-9a-f]{40}$/.test(source.upstream.revision) ||
      source.url !==
        `${source.upstream.repository}/archive/${source.upstream.revision}.tar.gz` ||
      typeof source.archiveRoot !== "string" ||
      !/^[a-zA-Z0-9_.-]+$/.test(source.archiveRoot) ||
      source.archiveRoot !==
        `${source.upstream.repository.split("/").at(-1)}-${source.upstream.revision}` ||
      !Array.isArray(source.paths) ||
      source.paths.length === 0 ||
      !Array.isArray(source.patches) ||
      names.has(source.name) ||
      destinations.has(source.destination)
    ) {
      throw new Error("invalid or duplicate vendor source");
    }
    names.add(source.name);
    destinations.add(source.destination);
    const paths = new Set<string>();
    for (const selected of source.paths) {
      if (
        !safeRelative(selected) ||
        paths.has(selected) ||
        [...paths].some(
          (existing) =>
            selected.startsWith(`${existing}/`) ||
            existing.startsWith(`${selected}/`),
        )
      ) {
        throw new Error("invalid or overlapping vendor paths");
      }
      paths.add(selected);
    }
    const patchNames = new Set<string>();
    for (const patch of source.patches) {
      if (
        !patch ||
        typeof patch.name !== "string" ||
        !/^[a-z0-9][a-z0-9-]*$/.test(patch.name) ||
        typeof patch.file !== "string" ||
        !/^patches\/(?:[a-zA-Z0-9_-]+\/)*[a-zA-Z0-9_.-]+\.patch$/.test(
          patch.file,
        ) ||
        typeof patch.description !== "string" ||
        !patch.description.trim() ||
        (patch.upstream !== undefined &&
          (typeof patch.upstream !== "string" ||
            !patch.upstream.startsWith("https://"))) ||
        patchNames.has(patch.name) ||
        patchFiles.has(patch.file)
      ) {
        throw new Error("invalid or duplicate vendor patch");
      }
      patchNames.add(patch.name);
      patchFiles.add(patch.file);
    }
  }
  return data.sources;
}

function readRegularFile(file: string, expected?: Stats) {
  const descriptor = openSync(
    file,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const info = fstatSync(descriptor);
    if (
      !info.isFile() ||
      (expected && (info.dev !== expected.dev || info.ino !== expected.ino))
    ) {
      throw new Error(`vendor file changed or is not regular: ${file}`);
    }
    return { info, bytes: readFileSync(descriptor) };
  } finally {
    closeSync(descriptor);
  }
}

function checkedArchive(file: string, source: Source): Buffer {
  const { bytes } = readRegularFile(file);
  if (hash(bytes) !== source.sha256) {
    throw new Error(`archive checksum mismatch: ${file}`);
  }
  return bytes;
}

export async function archiveFor(
  source: Source,
  cache: string,
): Promise<string> {
  mkdirSync(cache, { recursive: true });
  const destination = join(cache, `${source.sha256}.tar.gz`);
  if (lstatSync(destination, { throwIfNoEntry: false })) {
    checkedArchive(destination, source);
    return destination;
  }
  const response = await fetch(source.url, {
    redirect: "follow",
    signal: AbortSignal.timeout(120_000),
  });
  if (!response.ok) {
    throw new Error(
      `archive download failed: HTTP ${response.status} for ${id(source)}`,
    );
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (hash(bytes) !== source.sha256) {
    throw new Error(`archive checksum mismatch for ${id(source)}`);
  }
  const stage = mkdtempSync(join(cache, ".download-"));
  try {
    writeFileSync(join(stage, "archive"), bytes);
    renameSync(join(stage, "archive"), destination);
  } finally {
    rmSync(stage, { recursive: true, force: true });
  }
  return destination;
}

/** Include hidden files, executable bits, and symlink targets. */
export function treeEntries(
  root: string,
  ignoredTopLevel = new Set<string>(),
): Map<string, string> {
  if (!lstatSync(root).isDirectory()) {
    throw new Error(`expected source directory: ${root}`);
  }
  const entries = new Map<string, string>();
  function visit(directory: string, prefix: string) {
    for (const name of readdirSync(directory).sort()) {
      if (!prefix && ignoredTopLevel.has(name)) continue;
      if (name === ".git") {
        throw new Error(`unexpected Git metadata in vendor source: ${directory}`);
      }
      const file = join(directory, name);
      const key = `${prefix}${name}`;
      const info = lstatSync(file);
      if (info.isDirectory()) visit(file, `${key}/`);
      else if (info.isSymbolicLink()) entries.set(key, `link:${readlinkSync(file)}`);
      else if (info.isFile()) {
        const opened = readRegularFile(file, info);
        entries.set(
          key,
          `file:${opened.info.mode & 0o111 ? "x" : "-"}:${hash(opened.bytes)}`,
        );
      } else {
        throw new Error(`unsupported vendor entry: ${file}`);
      }
    }
  }
  visit(root, "");
  return entries;
}

export function sourceEntries(
  source: Source,
  root: string,
): Map<string, string> {
  return treeEntries(root, new Set([".build"]));
}

export function snapshotSource(
  _source: Source,
  current: string,
  destination: string,
): void {
  mkdirSync(destination, { recursive: true });
  for (const name of readdirSync(current)) {
    if (name === ".build") continue;
    cpSync(join(current, name), join(destination, name), {
      recursive: true,
      dereference: false,
      verbatimSymlinks: true,
    });
  }
}

export function isolatedGitEnvironment(
  cwd: string,
  inherited: NodeJS.ProcessEnv = process.env,
  gitIndexFile?: string | null,
): NodeJS.ProcessEnv {
  const env = { ...inherited };
  for (const key of Object.keys(env)) {
    if (key.startsWith("GIT_")) delete env[key];
  }
  if (gitIndexFile) env.GIT_INDEX_FILE = gitIndexFile;
  env.GIT_CEILING_DIRECTORIES = dirname(resolve(cwd));
  env.GIT_CONFIG_NOSYSTEM = "1";
  env.GIT_CONFIG_GLOBAL = "/dev/null";
  env.GIT_EDITOR = "true";
  env.GIT_TERMINAL_PROMPT = "0";
  return env;
}

export function gitBytes(cwd: string, args: string[], diff = false) {
  const env = isolatedGitEnvironment(cwd);
  const result = Bun.spawnSync(
    [
      "git",
      "-c",
      "core.filemode=true",
      "-c",
      "core.autocrlf=false",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "gc.auto=0",
      "-c",
      "maintenance.auto=false",
      "-c",
      "user.name=Vendor tooling",
      "-c",
      "user.email=vendor@localhost",
      ...args,
    ],
    { cwd, env, stdout: "pipe", stderr: "pipe" },
  );
  if (result.exitCode !== 0 && !(diff && result.exitCode === 1)) {
    throw new Error(
      `git ${args[0]} failed: ${result.stderr.toString().trim()}`,
    );
  }
  return result.stdout;
}

export function git(cwd: string, args: string[], diff = false): string {
  return gitBytes(cwd, args, diff).toString();
}

export function assertVendorIndexMatchesWorktree(
  cwd: string,
  inputs = vendorInputs,
  gitIndexFile: string | null | undefined = process.env.GIT_INDEX_FILE,
): void {
  const env = isolatedGitEnvironment(cwd, process.env, gitIndexFile);
  const run = (args: string[]) => {
    const result = Bun.spawnSync(["git", ...args, "--", ...inputs], {
      cwd,
      env,
      stdout: "pipe",
      stderr: "pipe",
    });
    if (result.exitCode !== 0) {
      throw new Error(
        `git ${args[0]} failed: ${result.stderr.toString().trim()}`,
      );
    }
    return result.stdout.toString().trim();
  };
  const changed = run(["diff", "--name-only"]);
  const untracked = run(["ls-files", "--others", "--exclude-standard"]);
  const mismatches = [changed, untracked].filter(Boolean).join("\n");
  if (mismatches) {
    throw new Error(
      `vendor-related index and working tree differ:\n${mismatches
        .split("\n")
        .map((file) => `  ${file}`)
        .join("\n")}\nStage the intended versions together or restore the working-tree-only edits before committing.`,
    );
  }
}

export function differences(
  expected: Map<string, string>,
  actual: Map<string, string>,
): string[] {
  return [...new Set([...expected.keys(), ...actual.keys()])]
    .sort()
    .filter((key) => expected.get(key) !== actual.get(key));
}

export async function extract(
  source: Source,
  archive: string,
  destination: string,
): Promise<void> {
  const stage = mkdtempSync(join(tmpdir(), "hubris-vendor-unpack-"));
  try {
    await new Bun.Archive(checkedArchive(archive, source)).extract(stage);
    const children = readdirSync(stage);
    if (children.length !== 1 || children[0] !== source.archiveRoot) {
      throw new Error(`unexpected archive root for ${id(source)}`);
    }
    const original = join(stage, source.archiveRoot);
    treeEntries(original);
    mkdirSync(destination, { recursive: true });
    for (const selected of source.paths) {
      const input = join(original, selected);
      const info = lstatSync(input, { throwIfNoEntry: false });
      if (!info) {
        throw new Error(`selected archive path is missing: ${selected}`);
      }
      const output = join(destination, selected);
      mkdirSync(dirname(output), { recursive: true });
      cpSync(input, output, {
        recursive: true,
        dereference: false,
        verbatimSymlinks: true,
      });
    }
    treeEntries(destination);
  } finally {
    rmSync(stage, { recursive: true, force: true });
  }
}

export function checkIdentity(source: Source, current: string): void {
  if (!lstatSync(current, { throwIfNoEntry: false })?.isDirectory()) {
    throw new Error(`vendor destination is missing: ${source.destination}`);
  }
  for (const selected of source.paths) {
    if (!lstatSync(join(current, selected), { throwIfNoEntry: false })) {
      throw new Error(`vendored path is missing: ${selected}`);
    }
  }
}

export function applyPatch(directory: string, file: string): void {
  if (readFileSync(file, "utf8").trim()) {
    git(directory, ["apply", "--whitespace=nowarn", resolve(file)]);
  }
}

export function diffTrees(before: string, after: string): string {
  const stage = mkdtempSync(join(tmpdir(), "hubris-vendor-diff-"));
  try {
    cpSync(before, join(stage, "a"), {
      recursive: true,
      dereference: false,
      verbatimSymlinks: true,
    });
    cpSync(after, join(stage, "b"), {
      recursive: true,
      dereference: false,
      verbatimSymlinks: true,
    });
    return git(
      stage,
      [
        "diff",
        "--no-index",
        "--no-prefix",
        "--no-ext-diff",
        "--no-textconv",
        "--binary",
        "--full-index",
        "--",
        "a",
        "b",
      ],
      true,
    );
  } finally {
    rmSync(stage, { recursive: true, force: true });
  }
}

export async function reproduce(
  source: Source,
  root: string,
  archive: string,
): Promise<void> {
  const stage = mkdtempSync(join(tmpdir(), "hubris-vendor-"));
  try {
    await extract(source, archive, stage);
    const current = sourceDirectory(root, source);
    const actual = sourceEntries(source, current);
    checkIdentity(source, current);
    for (const patch of source.patches) {
      applyPatch(stage, join(root, patch.file));
    }
    const changed = differences(treeEntries(stage), actual);
    if (changed.length) {
      throw new Error(
        `${id(source)} differs from archive + patches:\n${changed
          .map((file) => `  ${file}`)
          .join("\n")}\nUse vendor:status to resume an edit session; do not refresh unrelated drift.`,
      );
    }
  } finally {
    rmSync(stage, { recursive: true, force: true });
  }
}

async function main() {
  const [mode, selected, patch, ...rest] = Bun.argv.slice(2);
  if (
    !mode ||
    ![
      "check",
      "index-check",
      "start",
      "finish",
      "continue",
      "status",
      "cancel",
      "reopen",
    ].includes(mode) ||
    (rest.length > 0 &&
      !(mode === "start" && rest.length === 1 && rest[0] === "--adopt-edits")) ||
    (mode === "start" ? !selected || !patch : patch !== undefined) ||
    (!["check", "index-check", "status"].includes(mode) && !selected) ||
    (mode === "index-check" && selected !== undefined)
  ) {
    throw new Error(
      "usage: vendor.ts check|status [source] | index-check | start <source> <patch> [--adopt-edits] | finish|continue|reopen|cancel <source>",
    );
  }
  if (mode === "index-check") {
    assertVendorIndexMatchesWorktree(repository);
    console.log("vendor-related index matches the working tree");
    return;
  }
  const sources = readSources(join(recipeRoot, "sources.json"));
  const wanted = selected
    ? sources.filter((source) => source.name === selected)
    : sources;
  if (selected && !wanted.length) {
    throw new Error(`unknown vendored source: ${selected}`);
  }
  const { runSession, sessionStatus, withVendorLock } =
    await import("./vendor-session");
  const storage = join(repository, ".native/vendor");
  for (const source of wanted) {
    await withVendorLock(storage, source.name, async () => {
      if (mode === "status") {
        console.log(sessionStatus(source, storage));
      } else if (mode === "check") {
        const status = sessionStatus(source, storage);
        if (!status.endsWith(": no active session")) {
          throw new Error(
            `${status}\nFinish or cancel this session before verification.`,
          );
        }
        await reproduce(
          source,
          recipeRoot,
          await archiveFor(source, join(storage, "archives")),
        );
        console.log(
          `verified ${id(source)}: archive + patches matches vendored source`,
        );
      } else {
        const archive =
          mode === "start"
            ? await archiveFor(source, join(storage, "archives"))
            : undefined;
        await runSession(
          mode,
          source,
          recipeRoot,
          storage,
          patch,
          archive,
          rest[0] === "--adopt-edits",
        );
        console.log(sessionStatus(source, storage));
      }
    });
  }
  if (!sources.length) console.log("no vendored sources to verify");
}

if (import.meta.main) {
  try {
    await main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  }
}
