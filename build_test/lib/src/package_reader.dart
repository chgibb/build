// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:collection/collection.dart';
import 'package:glob/glob.dart';
import 'package:package_resolver/package_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:stream_transform/stream_transform.dart';

/// Resolves using a [SyncPackageResolver] before reading from the file system.
///
/// For a simple implementation that uses the current isolate's package
/// resolution logic (i.e. whatever you have generated in `.packages` in most
/// cases), use [currentIsolate]:
/// ```dart
/// var assetReader = await PackageAssetReader.currentIsolate();
/// ```
class PackageAssetReader extends AssetReader
    implements MultiPackageAssetReader {
  final SyncPackageResolver _packageResolver;

  /// What package is the originating build occurring in.
  final String _rootPackage;

  /// Wrap a [SyncPackageResolver] to identify where files are located.
  ///
  /// To use a normal [PackageResolver] use `asSync`:
  /// ```
  /// new PackageAssetReader(await packageResolver.asSync);
  /// ```
  PackageAssetReader(this._packageResolver, [this._rootPackage]);

  /// A [PackageAssetReader] with a single [packageRoot] configured.
  ///
  /// It is assumed that every _directory_ in [packageRoot] is a package where
  /// the name of the package is the name of the directory. This is similar to
  /// the older "packages" folder paradigm for resolution.
  factory PackageAssetReader.forPackageRoot(String packageRoot,
      [String rootPackage]) {
    // This purposefully doesn't use SyncPackageResolver.root, because that is
    // assuming a symlink collection and not directories, and this factory is
    // more useful for a user-created collection of folders for testing.
    final directory = new Directory(packageRoot);
    final packages = <String, String>{};
    for (final entity in directory.listSync()) {
      if (entity is Directory) {
        final name = p.basename(entity.path);
        packages[name] = entity.uri.toString();
      }
    }
    return new PackageAssetReader.forPackages(packages, rootPackage);
  }

  /// Returns a [PackageAssetReader] with a simple [packageToPath] mapping.
  factory PackageAssetReader.forPackages(Map<String, String> packageToPath,
          [String rootPackage]) =>
      new PackageAssetReader(
          new SyncPackageResolver.config(mapMap(packageToPath,
              value: (_, String v) =>
                  Uri.parse(p.absolute(v, 'lib')).replace(scheme: 'file'))),
          rootPackage);

  /// A reader that can resolve files known to the current isolate.
  ///
  /// A [rootPackage] should be provided for full API compatibility.
  static Future<PackageAssetReader> currentIsolate({String rootPackage}) async {
    var resolver = PackageResolver.current;
    return new PackageAssetReader(await resolver.asSync, rootPackage);
  }

  File _resolve(AssetId id) {
    final uri = id.uri;
    if (uri.isScheme('package')) {
      return new File.fromUri(_packageResolver.resolveUri(id.uri));
    }
    if (id.package == _rootPackage) {
      // TODO this assumes the cwd is the root package
      return new File(p.canonicalize(p.join(p.current, id.path)));
    }
    throw new UnsupportedError('Unabled to resolve $id');
  }

  @override
  Stream<AssetId> findAssets(Glob glob, {String package}) {
    package ??= _rootPackage;
    if (package == null) {
      throw new UnsupportedError(
          'Root package must be provided to use `findAssets` without an '
          'explicit `package`.');
    }
    var packageLibDir = _packageResolver.packageConfigMap[package];
    if (packageLibDir == null) {
      throw new UnsupportedError('Unable to find package $package');
    }

    var packageFiles = new Directory.fromUri(packageLibDir)
        .list(recursive: true)
        .where((e) => e is File)
        .map((f) =>
            p.join('lib', p.relative(f.path, from: p.fromUri(packageLibDir))));
    if (package == _rootPackage) {
      // TODO this assumes the cwd is the root package
      packageFiles = packageFiles.transform(merge(Directory.current
          .list(recursive: true)
          .where((e) => e is File)
          .map((f) => p.relative(f.path, from: Directory.current.path))
          .where((p) => !(p.startsWith('packages/') || p.startsWith('lib/')))));
    }
    return packageFiles.where(glob.matches).map((p) => new AssetId(package, p));
  }

  @override
  Future<bool> canRead(AssetId id) {
    final file = _resolve(id);
    if (file == null) {
      return new Future.value(false);
    }
    return file.exists();
  }

  @override
  Future<List<int>> readAsBytes(AssetId id) {
    final file = _resolve(id);
    if (file == null) {
      throw new ArgumentError('Could not read $id.');
    }
    return file.readAsBytes();
  }

  @override
  Future<String> readAsString(AssetId id, {Encoding encoding = utf8}) {
    final file = _resolve(id);
    if (file == null) {
      throw new ArgumentError('Could not read $id.');
    }
    return file.readAsString(encoding: encoding);
  }
}
