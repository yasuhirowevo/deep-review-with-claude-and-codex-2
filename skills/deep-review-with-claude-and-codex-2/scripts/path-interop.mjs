import path from "node:path";

export function toBashAbsolutePath(filePath) {
  if (typeof filePath !== "string") {
    throw new TypeError("filePath must be a string");
  }
  const slashPath = filePath.replaceAll("\\", "/");
  return slashPath.replace(/^([A-Za-z]):/, (_, drive) =>
    `/${drive.toLowerCase()}`,
  );
}

export function toNativeAbsolutePath(filePath, platform = process.platform) {
  if (typeof filePath !== "string") {
    throw new TypeError("filePath must be a string");
  }
  if (platform !== "win32") return filePath;
  const slashPath = filePath.replaceAll("\\", "/");
  const drivePath = slashPath.match(/^\/([A-Za-z])(?:\/(.*))?$/u);
  if (!drivePath) return filePath;
  return `${drivePath[1].toUpperCase()}:/${drivePath[2] ?? ""}`;
}

export function sameNativeParentDirectory(
  leftFilePath,
  rightFilePath,
  platform = process.platform,
) {
  if (
    typeof leftFilePath !== "string" ||
    typeof rightFilePath !== "string"
  ) {
    throw new TypeError("file paths must be strings");
  }
  const nativePath = platform === "win32" ? path.win32 : path.posix;
  const leftParent = nativePath.dirname(leftFilePath);
  const rightParent = nativePath.dirname(rightFilePath);
  if (platform !== "win32") return leftParent === rightParent;
  return toBashAbsolutePath(leftParent) === toBashAbsolutePath(rightParent);
}

export function replacePortablePathPrefix(
  filePath,
  sourcePrefix,
  destinationPrefix,
) {
  const portablePath = toBashAbsolutePath(filePath);
  const portableSource = toBashAbsolutePath(sourcePrefix).replace(/\/+$/u, "");
  const portableDestination = toBashAbsolutePath(destinationPrefix).replace(
    /\/+$/u,
    "",
  );
  if (
    portablePath !== portableSource &&
    !portablePath.startsWith(`${portableSource}/`)
  ) {
    return filePath;
  }
  return `${portableDestination}${portablePath.slice(portableSource.length)}`;
}
