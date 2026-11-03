String extendedPath(String path) {
  final normal = path.replaceAll('/', r'\');
  if (normal.startsWith(r'\\?\')) return normal;
  if (normal.startsWith(r'\\')) return r'\\?\UNC\' + normal.substring(2);
  return r'\\?\' + normal;
}

String stripExtendedPrefix(String path) {
  if (path.startsWith(r'\\?\UNC\')) return r'\\' + path.substring(8);
  if (path.startsWith(r'\\?\')) return path.substring(4);
  return path;
}
