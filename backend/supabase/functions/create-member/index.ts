import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const allowedPermissions = new Set([
  "dashboard.view",
  "products.view", "products.create", "products.edit", "products.archive",
  "inventory.view", "inventory.adjust", "inventory.count", "inventory.transfer",
  "sales.view", "sales.create", "sales.cancel", "sales.return", "sales.discount",
  "customers.view", "customers.create", "customers.edit",
  "suppliers.view", "suppliers.create", "suppliers.edit",
  "purchases.view", "purchases.create", "purchases.return",
  "accounts.view", "accounts.customer.receipt", "accounts.supplier.payment", "accounts.adjust",
  "cashbook.view", "cashbook.session.open", "cashbook.session.close", "cashbook.adjust",
  "branches.view", "branches.manage", "warehouses.view", "warehouses.manage",
  "expenses.view", "expenses.create", "expenses.edit", "expenses.delete",
  "reports.view", "reports.profit.view", "data.export", "data.backup", "data.import",
  "users.view", "users.create", "users.edit", "users.deactivate",
  "settings.view", "settings.edit", "audit.view",
]);

const syntheticEmailDomain = "users.smart-merchant.invalid";

function response(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return response(405, { error: "method_not_allowed" });
  }

  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return response(401, { error: "authentication_required" });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return response(500, { error: "server_configuration_missing" });
  }

  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: authData, error: authError } = await callerClient.auth.getUser();
  if (authError || !authData.user) {
    return response(401, { error: "invalid_session" });
  }

  let payload: {
    business_id?: unknown;
    username?: unknown;
    display_name?: unknown;
    password?: unknown;
    permission_keys?: unknown;
  };
  try {
    payload = await request.json();
  } catch {
    return response(400, { error: "invalid_json" });
  }

  const businessId = typeof payload.business_id === "string"
    ? payload.business_id
    : "";
  const username = typeof payload.username === "string"
    ? payload.username.trim().toLowerCase()
    : "";
  const displayName = typeof payload.display_name === "string"
    ? payload.display_name.trim()
    : "";
  const password = typeof payload.password === "string" ? payload.password : "";
  const permissionKeys = Array.isArray(payload.permission_keys)
    ? payload.permission_keys
    : [];

  if (!businessId ||
      !/^[a-z0-9][a-z0-9_.-]{2,31}$/.test(username) ||
      displayName.length < 1 || displayName.length > 120 ||
      password.length < 10 || password.length > 128) {
    return response(400, {
      error: "invalid_account_details",
      message: "Use a 3-32 character username, display name, and password of at least 10 characters.",
    });
  }

  if (!permissionKeys.every((key) =>
    typeof key === "string" && allowedPermissions.has(key)
  )) {
    return response(400, { error: "invalid_permission_key" });
  }
  const uniquePermissionKeys = [...new Set(permissionKeys as string[])];

  const { data: actorMember, error: actorError } = await adminClient
    .from("business_members")
    .select("id,is_owner")
    .eq("business_id", businessId)
    .eq("user_id", authData.user.id)
    .eq("is_active", true)
    .maybeSingle();

  if (actorError) return response(500, { error: "membership_check_failed" });
  if (!actorMember) return response(403, { error: "not_a_business_member" });

  let actorPermissions = new Set<string>();
  if (!actorMember.is_owner) {
    const { data: grants, error: grantsError } = await adminClient
      .from("member_permissions")
      .select("permission_key")
      .eq("business_id", businessId)
      .eq("member_id", actorMember.id)
      .eq("allowed", true);

    if (grantsError) return response(500, { error: "permission_check_failed" });
    actorPermissions = new Set((grants ?? []).map((grant) => grant.permission_key));

    if (!actorPermissions.has("users.create") || !actorPermissions.has("users.edit")) {
      return response(403, { error: "user_creation_and_permission_management_required" });
    }

    // Delegated administrators may grant only capabilities they themselves have.
    // This prevents privilege escalation and prevents them from creating owners.
    if (uniquePermissionKeys.some((key) => !actorPermissions.has(key))) {
      return response(403, { error: "cannot_grant_unheld_permission" });
    }
  }

  const loginEmail = `${username}@${syntheticEmailDomain}`;
  const { data: createdAuth, error: authCreateError } = await adminClient.auth.admin
    .createUser({
      email: loginEmail,
      password,
      email_confirm: true,
      user_metadata: {
        username,
        display_name: displayName,
        account_type: "business_member",
      },
    });

  if (authCreateError || !createdAuth.user) {
    const duplicate = authCreateError?.message.toLowerCase().includes("already") ?? false;
    return response(duplicate ? 409 : 400, {
      error: duplicate ? "username_unavailable" : "account_creation_failed",
    });
  }

  const newUserId = createdAuth.user.id;
  let memberId: string | null = null;

  try {
    const { data: member, error: memberError } = await adminClient
      .from("business_members")
      .insert({
        business_id: businessId,
        user_id: newUserId,
        display_name: displayName,
        is_owner: false,
        is_active: true,
      })
      .select("id")
      .single();

    if (memberError || !member) {
      throw new Error("member_creation_failed");
    }
    memberId = member.id;

    const { error: loginNameError } = await adminClient
      .from("member_login_names")
      .insert({
        business_id: businessId,
        member_id: memberId,
        username,
      });
    if (loginNameError) {
      throw new Error(loginNameError.code === "23505"
        ? "username_unavailable"
        : "username_record_creation_failed");
    }

    if (uniquePermissionKeys.length > 0) {
      const { error: permissionError } = await adminClient
        .from("member_permissions")
        .insert(uniquePermissionKeys.map((permissionKey) => ({
          business_id: businessId,
          member_id: memberId,
          permission_key: permissionKey,
          allowed: true,
        })));
      if (permissionError) throw new Error("permission_assignment_failed");
    }

    const { error: auditError } = await adminClient.from("audit_events").insert({
      business_id: businessId,
      actor_user_id: authData.user.id,
      action_key: "users.create",
      entity_type: "business_member",
      entity_id: memberId,
      metadata: {
        username,
        display_name: displayName,
        permission_keys: uniquePermissionKeys,
      },
    });
    if (auditError) {
      // Do not report a successful account creation when its required audit
      // record could not be persisted. The catch block compensates by removing
      // the membership and Auth user created above.
      throw new Error("audit_event_creation_failed");
    }

    return response(201, {
      member_id: memberId,
      user_id: newUserId,
      username,
      display_name: displayName,
      permission_keys: uniquePermissionKeys,
      login_method: "username_password",
    });
  } catch (error) {
    let cleanupFailure: "membership" | "auth_user" | null = null;

    if (memberId) {
      const { error: membershipCleanupError } = await adminClient
        .from("business_members")
        .delete()
        .eq("id", memberId);

      if (membershipCleanupError) {
        // If deletion fails, deactivate the membership as a fail-closed fallback.
        // Do not delete the Auth user while a membership may still reference it.
        const { error: deactivationError } = await adminClient
          .from("business_members")
          .update({ is_active: false })
          .eq("id", memberId);
        cleanupFailure = "membership";
        if (deactivationError) {
          console.error("create-member compensation failed", {
            stage: "membership_delete_and_deactivation",
          });
        } else {
          console.error("create-member compensation required membership deactivation", {
            stage: "membership_delete",
          });
        }
      }
    }

    if (!cleanupFailure) {
      const { error: authCleanupError } = await adminClient.auth.admin.deleteUser(newUserId);
      if (authCleanupError) {
        cleanupFailure = "auth_user";
        console.error("create-member compensation failed", {
          stage: "auth_user_delete",
        });
      }
    }

    if (cleanupFailure) {
      return response(500, { error: "account_creation_failed_cleanup_required" });
    }

    const message = error instanceof Error ? error.message : "account_creation_failed";
    return response(message === "username_unavailable" ? 409 : 500, { error: message });
  }
});
