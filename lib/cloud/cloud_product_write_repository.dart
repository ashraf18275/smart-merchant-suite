import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/sync_outbox_repository.dart';

/// Small seam around Supabase RPCs so the contract can be tested without a
/// live backend or an authenticated production session.
abstract interface class CloudProductRpcClient {
  Future<Object?> call(String function, Map<String, dynamic> parameters);
}

class SupabaseCloudProductRpcClient implements CloudProductRpcClient {
  SupabaseCloudProductRpcClient(this._client);

  final SupabaseClient _client;

  @override
  Future<Object?> call(
    String function,
    Map<String, dynamic> parameters,
  ) async {
    return await _client.rpc(function, params: parameters);
  }
}

/// Maps product Outbox events to the idempotent server RPC contract.
///
/// This adapter is intentionally not a sync worker. It is called only by a
/// future, explicitly enabled dispatcher after tenant and entity mappings have
/// been verified.
class CloudProductWriteRepository {
  CloudProductWriteRepository(this._rpc);

  final CloudProductRpcClient _rpc;

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  Future<String> createFromEvent(SyncOutboxEvent event) async {
    _validateEvent(event, expectedAction: 'create');
    final record = _readFields(event.payload['record'], 'record');
    final result = await _rpc.call('create_cloud_product', {
      'p_business_id': _requireUuid(event.businessId, 'business_id'),
      'p_operation_id': _requireUuid(event.operationId, 'operation_id'),
      'p_name': record['name'],
      'p_sku': record['sku'],
      'p_cost_minor': record['cost_minor'],
      'p_price_minor': record['price_minor'],
      'p_is_active': record['is_active'],
    });
    return _readRemoteId(result);
  }

  Future<String> updateFromEvent(
    SyncOutboxEvent event, {
    required String remoteProductId,
  }) async {
    _validateEvent(event, expectedAction: 'update');
    final base = _readFields(event.payload['base'], 'base');
    final record = _readFields(event.payload['record'], 'record');
    final result = await _rpc.call('update_cloud_product', {
      'p_business_id': _requireUuid(event.businessId, 'business_id'),
      'p_operation_id': _requireUuid(event.operationId, 'operation_id'),
      'p_product_id': _requireUuid(remoteProductId, 'remote_product_id'),
      'p_base_name': base['name'],
      'p_base_sku': base['sku'],
      'p_base_cost_minor': base['cost_minor'],
      'p_base_price_minor': base['price_minor'],
      'p_base_is_active': base['is_active'],
      'p_name': record['name'],
      'p_sku': record['sku'],
      'p_cost_minor': record['cost_minor'],
      'p_price_minor': record['price_minor'],
      'p_is_active': record['is_active'],
    });
    return _readRemoteId(result);
  }

  void _validateEvent(
    SyncOutboxEvent event, {
    required String expectedAction,
  }) {
    if (event.entityType != 'product' || event.action != expectedAction) {
      throw StateError('unsupported_product_outbox_event');
    }
    if (event.payload['payload_schema_version'] != 1) {
      throw FormatException('unsupported_product_payload_schema');
    }
    _requireUuid(event.businessId, 'business_id');
    _requireUuid(event.operationId, 'operation_id');
    if (event.localEntityId.trim().isEmpty) {
      throw FormatException('missing_local_product_id');
    }
  }

  Map<String, dynamic> _readFields(Object? value, String label) {
    if (value is! Map<String, dynamic>) {
      throw FormatException('invalid_product_$label');
    }
    final name = value['name'];
    final sku = value['sku'];
    final cost = value['cost_minor'];
    final price = value['price_minor'];
    final active = value['is_active'];
    if (name is! String || name.trim().isEmpty || name.trim().length > 250) {
      throw FormatException('invalid_product_$label.name');
    }
    if (sku != null && sku is! String) {
      throw FormatException('invalid_product_$label.sku');
    }
    if (cost is! int || cost < 0) {
      throw FormatException('invalid_product_$label.cost_minor');
    }
    if (price is! int || price < 0) {
      throw FormatException('invalid_product_$label.price_minor');
    }
    if (active is! bool) {
      throw FormatException('invalid_product_$label.is_active');
    }
    final normalizedSku = sku is String ? sku.trim() : null;
    if ((normalizedSku?.length ?? 0) > 120) {
      throw FormatException('invalid_product_$label.sku');
    }
    return {
      'name': name.trim(),
      'sku': normalizedSku == null || normalizedSku.isEmpty
          ? null
          : normalizedSku,
      'cost_minor': cost,
      'price_minor': price,
      'is_active': active,
    };
  }

  String _requireUuid(String? value, String label) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || !_uuidPattern.hasMatch(normalized)) {
      throw FormatException('invalid_$label');
    }
    return normalized;
  }

  String _readRemoteId(Object? value) {
    if (value is! String) {
      throw FormatException('invalid_cloud_product_rpc_result');
    }
    return _requireUuid(value, 'remote_product_id');
  }
}
