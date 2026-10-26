/// RFC 4180-style CSV encoding with a UTF-8 BOM for spreadsheet compatibility.
String encodeCsv(List<List<Object?>> rows) {
  String cell(Object? value) {
    final text = value?.toString() ?? '';
    final escaped = text.replaceAll('"', '""');
    if (text.contains(',') || text.contains('"') || text.contains('\r') ||
        text.contains('\n')) {
      return '"$escaped"';
    }
    return escaped;
  }

  return '\uFEFF${rows.map((row) => row.map(cell).join(',')).join('\r\n')}\r\n';
}
