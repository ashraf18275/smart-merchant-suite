class CloudBusiness {
  const CloudBusiness({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  final String id;
  final String name;
  final DateTime? createdAt;

  factory CloudBusiness.fromMap(Map<String, dynamic> row) => CloudBusiness(
        id: row['id'] as String,
        name: row['name'] as String,
        createdAt: row['created_at'] == null
            ? null
            : DateTime.tryParse(row['created_at'] as String),
      );
}
