import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/cloud/cloud_product_write_repository.dart';
import 'package:smart_merchant_suite/data/sync_outbox_repository.dart';

const _businessId = '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _operationId = '8f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _remoteProductId = '9f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';

class _RpcCall {
  const _RpcCall(this.function, this.parameters);
  final String function;
  final Map<String, dynamic> parameters;
}

class _FakeRpcClient implements CloudProductRpcClient {
  Object? result = _remoteProductId;
  final calls = <_RpcCall>[];

  @override
  Future<Object?> call(String function, Map<String, dynamic> parameters) async {
    calls.add(_RpcCall(function, Map<String, dynamic>.from(parameters)));
    return result;
  }
}

SyncOutboxEvent _event({
  String? businessId = _businessId,
  String entityType = 'product',
  String action = 'create',
  Map<String, dynamic>? payload,
}) {
  return SyncOutboxEvent(
    eventId: '7f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d',
    operationId: _operationId,
    businessId: businessId,
    entityType: entityType,
    localEntityId: '42',
    action: action,
    payload: payload ??
        {
          'payload_schema_version': 1,
          'record': {
            'name': 'قلم',
            'sku': 'PEN-01',
            'cost_minor': 100,
            'price_minor': 150,
            'is_active': false,
          },
        },
    status: 'processing',
    attempts: 1,
  );
}

void main() {
  late _FakeRpcClient rpc;
  late CloudProductWriteRepository repository;

  setUp(() {
    rpc = _FakeRpcClient();
    repository = CloudProductWriteRepository(rpc);
  });

  test('maps a create event to the exact idempotent RPC contract', () async {
    final remoteId = await repository.createFromEvent(_event());

    expect(remoteId, _remoteProductId);
    expect(rpc.calls, hasLength(1));
    expect(rpc.calls.single.function, 'create_cloud_product');
    expect(rpc.calls.single.parameters, {
      'p_business_id': _businessId,
      'p_operation_id': _operationId,
      'p_name': 'قلم',
      'p_sku': 'PEN-01',
      'p_cost_minor': 100,
      'p_price_minor': 150,
      'p_is_active': false,
    });
    expect(rpc.calls.single.parameters.values, isNot(contains('42')));
  });

  test('maps an update event with base snapshot and mapped cloud UUID', () async {
    final event = _event(
      action: 'update',
      payload: {
        'payload_schema_version': 1,
        'base': {
          'name': 'قلم',
          'sku': 'PEN-01',
          'cost_minor': 90,
          'price_minor': 140,
          'is_active': true,
        },
        'record': {
          'name': 'قلم أزرق',
          'sku': 'PEN-01',
          'cost_minor': 100,
          'price_minor': 150,
          'is_active': false,
        },
      },
    );

    final remoteId = await repository.updateFromEvent(
      event,
      remoteProductId: _remoteProductId,
    );

    expect(remoteId, _remoteProductId);
    expect(rpc.calls, hasLength(1));
    expect(rpc.calls.single.function, 'update_cloud_product');
    expect(rpc.calls.single.parameters, {
      'p_business_id': _businessId,
      'p_operation_id': _operationId,
      'p_product_id': _remoteProductId,
      'p_base_name': 'قلم',
      'p_base_sku': 'PEN-01',
      'p_base_cost_minor': 90,
      'p_base_price_minor': 140,
      'p_base_is_active': true,
      'p_name': 'قلم أزرق',
      'p_sku': 'PEN-01',
      'p_cost_minor': 100,
      'p_price_minor': 150,
      'p_is_active': false,
    });
    expect(rpc.calls.single.parameters.values, isNot(contains('42')));
  });

  test('does not call RPC for an unbound or malformed tenant identity', () async {
    await expectLater(
      repository.createFromEvent(_event(businessId: null)),
      throwsFormatException,
    );
    await expectLater(
      repository.createFromEvent(_event(businessId: 'business-a')),
      throwsFormatException,
    );
    expect(rpc.calls, isEmpty);
  });

  test('rejects unsupported entity, action and payload versions', () async {
    await expectLater(
      repository.createFromEvent(_event(entityType: 'inventory_movement')),
      throwsStateError,
    );
    await expectLater(
      repository.createFromEvent(_event(action: 'update')),
      throwsStateError,
    );
    await expectLater(
      repository.createFromEvent(_event(payload: {
        'payload_schema_version': 2,
        'record': {
          'name': 'قلم',
          'sku': null,
          'cost_minor': 1,
          'price_minor': 2,
          'is_active': true,
        },
      })),
      throwsFormatException,
    );
    expect(rpc.calls, isEmpty);
  });

  test('requires a mapped cloud product UUID before update', () async {
    final event = _event(
      action: 'update',
      payload: {
        'payload_schema_version': 1,
        'base': {
          'name': 'قلم', 'sku': null, 'cost_minor': 1,
          'price_minor': 2, 'is_active': true,
        },
        'record': {
          'name': 'قلم جديد', 'sku': null, 'cost_minor': 1,
          'price_minor': 3, 'is_active': true,
        },
      },
    );

    await expectLater(
      repository.updateFromEvent(event, remoteProductId: '42'),
      throwsFormatException,
    );
    expect(rpc.calls, isEmpty);
  });

  test('rejects malformed payload fields and non-UUID RPC results', () async {
    await expectLater(
      repository.createFromEvent(_event(payload: {
        'payload_schema_version': 1,
        'record': {
          'name': 'قلم',
          'sku': null,
          'cost_minor': 1.5,
          'price_minor': 2,
          'is_active': true,
        },
      })),
      throwsFormatException,
    );
    expect(rpc.calls, isEmpty);

    rpc.result = 'not-a-uuid';
    await expectLater(repository.createFromEvent(_event()), throwsFormatException);
    expect(rpc.calls, hasLength(1));
  });
}
