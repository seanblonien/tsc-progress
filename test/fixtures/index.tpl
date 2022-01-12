// @ts-nocheck
import { isAbsolute, resolve, sep } from 'path';
import { Job } from './node-file-trace';

// node resolver
// custom implementation to emit only needed package.json files for resolver
// (package.json files are emitted as they are hit)
export default function resolveDependency (specifier: string, parent: string, job: Job, cjsResolve = true) {
  let resolved: string | string[];
  if (isAbsolute(specifier) || specifier === '.' || specifier === '..' || specifier.startsWith('./') || specifier.startsWith('../')) {
    const trailingSlash = specifier.endsWith('/');
    resolved = resolvePath(resolve(parent, '..', specifier) + (trailingSlash ? '/' : ''), parent, job);
  }
  else if (specifier[0] === '#') {
    resolved = packageImportsResolve(specifier, parent, job, cjsResolve);
  }
  else {
    resolved = resolvePackage(specifier, parent, job, cjsResolve);
  }

  if (Array.isArray(resolved)) {
    return resolved.map(resolved => job.realpath(resolved, parent));
  } else if (resolved.startsWith('node:')) {
    return resolved;
  } else {
    return job.realpath(resolved, parent);
  }
};

function resolvePath (path: string, parent: string, job: Job): string {
  const result = resolveFile(path, parent, job) || resolveDir(path, parent, job);
  if (!result) {
    throw new NotFoundError(path, parent);
  }
  return result;
}

function resolveFile (path: string, parent: string, job: Job): string | undefined {
  if (path.endsWith('/')) return undefined;
  path = job.realpath(path, parent);
  if (job.isFile(path)) return path;
  if (job.ts && path.startsWith(job.base) && path.substr(job.base.length).indexOf(sep + 'node_modules' + sep) === -1 && job.isFile(path + '.ts')) return path + '.ts';
  if (job.ts && path.startsWith(job.base) && path.substr(job.base.length).indexOf(sep + 'node_modules' + sep) === -1 && job.isFile(path + '.tsx')) return path + '.tsx';
  if (job.isFile(path + '.js')) return path + '.js';
  if (job.isFile(path + '.json')) return path + '.json';
  if (job.isFile(path + '.node')) return path + '.node';
  return undefined;
}

function resolveDir (path: string, parent: string, job: Job) {
  if (path.endsWith('/')) path = path.slice(0, -1);
  if (!job.isDir(path)) return;
  const pkgCfg = getPkgCfg(path, job);
  if (pkgCfg && typeof pkgCfg.main === 'string') {
    const resolved = resolveFile(resolve(path, pkgCfg.main), parent, job) || resolveFile(resolve(path, pkgCfg.main, 'index'), parent, job);
    if (resolved) {
      job.emitFile(path + sep + 'package.json', 'resolve', parent);
      return resolved;
    }
  }
  return resolveFile(resolve(path, 'index'), parent, job);
}

class NotFoundError extends Error {
  public code: string;
  constructor(specifier: string, parent: string) {
    super("Cannot find module '" + specifier + "' loaded from " + parent);
    this.code = 'MODULE_NOT_FOUND';
  }
}

const nodeBuiltins = new Set<string>([...require("repl")._builtinLibs, "constants", "module", "timers", "console", "_stream_writable", "_stream_readable", "_stream_duplex", "process", "sys"]);

function getPkgName (name: string) {
  const segments = name.split('/');
  if (name[0] === '@' && segments.length > 1)
    return segments.length > 1 ? segments.slice(0, 2).join('/') : null;
  return segments.length ? segments[0] : null;
}

type PackageTarget = string | PackageTarget[] | { [key: string]: PackageTarget } | null;

interface PkgCfg {
  name: string | undefined;
  main: string | undefined;
  exports: PackageTarget;
  imports: { [key: string]: PackageTarget };
}

function getPkgCfg (pkgPath: string, job: Job): PkgCfg | undefined {
  const pjsonSource = job.readFile(pkgPath + sep + 'package.json');
  if (pjsonSource) {
    try {
      return JSON.parse(pjsonSource.toString());
    }
    catch (e) {}
  }
  return undefined;
}

function getExportsTarget(exports: PackageTarget, conditions: string[], cjsResolve: boolean): string | null | undefined {
  if (typeof exports === 'string') {
    return exports;
  }
  else if (exports === null) {
    return exports;
  }
  else if (Array.isArray(exports)) {
    for (const item of exports) {
      const target = getExportsTarget(item, conditions, cjsResolve);
      if (target === null || typeof target === 'string' && target.startsWith('./'))
        return target;
    }
  }
  else if (typeof exports === 'object') {
    for (const condition of Object.keys(exports)) {
      if (condition === 'default' ||
          condition === 'require' && cjsResolve ||
          condition === 'import' && !cjsResolve ||
          conditions.includes(condition)) {
        const target = getExportsTarget(exports[condition], conditions, cjsResolve);
        if (target !== undefined)
          return target;
      }
    }
  }

  return undefined;
}

function resolveExportsImports (pkgPath: string, obj: PackageTarget, subpath: string, job: Job, isImports: boolean, cjsResolve: boolean): string | undefined {
  let matchObj: { [key: string]: PackageTarget };
  if (isImports) {
    if (!(typeof obj === 'object' && !Array.isArray(obj) && obj !== null))
      return undefined;
    matchObj = obj;
  } else if (typeof obj === 'string' || Array.isArray(obj) || obj === null ||
      typeof obj === 'object' && Object.keys(obj).length && Object.keys(obj)[0][0] !== '.') {
    matchObj = { '.' : obj };
  } else {
    matchObj = obj;
  }
  
  if (subpath in matchObj) {
    const target = getExportsTarget(matchObj[subpath], job.conditions, cjsResolve);
    if (typeof target === 'string' && target.startsWith('./'))
      return pkgPath + target.slice(1);
  }
  for (const match of Object.keys(matchObj).sort((a, b) => b.length - a.length)) {
    if (match.endsWith('*') && subpath.startsWith(match.slice(0, -1))) {
      const target = getExportsTarget(matchObj[match], job.conditions, cjsResolve);
      if (typeof target === 'string' && target.startsWith('./'))
        return pkgPath + target.slice(1).replace(/\*/g, subpath.slice(match.length - 1));
    }
    if (!match.endsWith('/'))
      continue;
    if (subpath.startsWith(match)) {
      const target = getExportsTarget(matchObj[match], job.conditions, cjsResolve);
      if (typeof target === 'string' && target.endsWith('/') && target.startsWith('./'))
        return pkgPath + target.slice(1) + subpath.slice(match.length);
    }
  }
  return undefined;
}

function packageImportsResolve (name: string, parent: string, job: Job, cjsResolve: boolean): string {
  if (name !== '#' && !name.startsWith('#/') && job.conditions) {
    const pjsonBoundary = job.getPjsonBoundary(parent);
    if (pjsonBoundary) {
      const pkgCfg = getPkgCfg(pjsonBoundary, job);
      const { imports: pkgImports } = pkgCfg || {};
      if (pkgCfg && pkgImports !== null && pkgImports !== undefined) {
        let importsResolved = resolveExportsImports(pjsonBoundary, pkgImports, name, job, true, cjsResolve);
        if (importsResolved) {
          if (cjsResolve)
            importsResolved = resolveFile(importsResolved, parent, job) || resolveDir(importsResolved, parent, job);
          else if (!job.isFile(importsResolved))
            throw new NotFoundError(importsResolved, parent);
          if (importsResolved) {
            job.emitFile(pjsonBoundary + sep + 'package.json', 'resolve', parent);
            return importsResolved;
          }
        }
      }
    }
  }
  throw new NotFoundError(name, parent);
}

function resolvePackage (name: string, parent: string, job: Job, cjsResolve: boolean): string | string [] {
  let packageParent = parent;
  if (nodeBuiltins.has(name)) return 'node:' + name;

  const pkgName = getPkgName(name) || '';
  
  // package own name resolution
  let selfResolved: string | undefined;
  if (job.conditions) {
    const pjsonBoundary = job.getPjsonBoundary(parent);
    if (pjsonBoundary) {
      const pkgCfg = getPkgCfg(pjsonBoundary, job);
      const { exports: pkgExports } = pkgCfg || {};
      if (pkgCfg && pkgCfg.name && pkgExports !== null && pkgExports !== undefined) {
        selfResolved = resolveExportsImports(pjsonBoundary, pkgExports, '.' + name.slice(pkgName.length), job, false, cjsResolve);
        if (selfResolved) {
          if (cjsResolve)
            selfResolved = resolveFile(selfResolved, parent, job) || resolveDir(selfResolved, parent, job);
          else if (!job.isFile(selfResolved))
            throw new NotFoundError(selfResolved, parent);
        }
        if (selfResolved)
          job.emitFile(pjsonBoundary + sep + 'package.json', 'resolve', parent);
      }
    }
  }

  let separatorIndex: number;
  const rootSeparatorIndex = packageParent.indexOf(sep);
  while ((separatorIndex = packageParent.lastIndexOf(sep)) > rootSeparatorIndex) {
    packageParent = packageParent.substr(0, separatorIndex);
    const nodeModulesDir = packageParent + sep + 'node_modules';
    const stat = job.stat(nodeModulesDir);
    if (!stat || !stat.isDirectory()) continue;
    const pkgCfg = getPkgCfg(nodeModulesDir + sep + pkgName, job);
    const { exports: pkgExports } = pkgCfg || {};
    if (job.conditions && pkgExports !== undefined && pkgExports !== null && !selfResolved) {
      let legacyResolved;
      if (!job.exportsOnly)
        legacyResolved = resolveFile(nodeModulesDir + sep + name, parent, job) || resolveDir(nodeModulesDir + sep + name, parent, job);
      let resolved = resolveExportsImports(nodeModulesDir + sep + pkgName, pkgExports, '.' + name.slice(pkgName.length), job, false, cjsResolve);
      if (resolved) {
        if (cjsResolve)
          resolved = resolveFile(resolved, parent, job) || resolveDir(resolved, parent, job);
        else if (!job.isFile(resolved))
          throw new NotFoundError(resolved, parent);
      }
      if (resolved) {
        job.emitFile(nodeModulesDir + sep + pkgName + sep + 'package.json', 'resolve', parent);
        if (legacyResolved && legacyResolved !== resolved)
          return [resolved, legacyResolved];
        return resolved;
      }
      if (legacyResolved)
        return legacyResolved;
    }
    else {
      const resolved = resolveFile(nodeModulesDir + sep + name, parent, job) || resolveDir(nodeModulesDir + sep + name, parent, job);
      if (resolved) {
        if (selfResolved && selfResolved !== resolved)
          return [resolved, selfResolved];
        return resolved;
      }
    }
  }
  if (selfResolved) return selfResolved;
  if (Object.hasOwnProperty.call(job.paths, name)) {
    return job.paths[name];
  }
  for (const path of Object.keys(job.paths)) {
    if (path.endsWith('/') && name.startsWith(path)) {
      const pathTarget = job.paths[path] + name.slice(path.length);
      const resolved = resolveFile(pathTarget, parent, job) || resolveDir(pathTarget, parent, job);
      if (!resolved) {
        throw new NotFoundError(name, parent);
      }
      return resolved;
    }
  }
  throw new NotFoundError(name, parent);
}