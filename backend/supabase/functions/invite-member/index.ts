import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const allowedPermissions = new Set([
  "dashboard.view",
  "products.view", "products.create", "products.edit", "products.archive",
  "inventory.view", "inventory.adjust", "inventory.count",
  "sales.view", "sales.create", "sales.cancel", "sales.return",
  "expenses.view", "expenses.create", "expenses.edit", "expenses.delete",
  "reports.view", "reports.profit.view", "data.export", "data.backup",
  "users.view", "users.create", "users.edit", "users.deactivate",
  "settings.view", "settings.edit", "audit.view",
]);

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
    email?: unknown;
    display_name?: unknown;
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
  const email = typeof payload.email === "string"
    ? payload.email.trim().toLowerCase()
    : "";
  const displayName = typeof payload.display_name === "string"
    ? payload.display_name.trim()
    : "";
  const permissionKeys = Array.isArray(payload.permission_keys)
    ? payload.permission_keys
    : [];

  const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!businessId || !emailPattern.test(email) ||
      displayName.length < 1 || displayName.length > 120) {
    return response(400, { error: "invalid_member_details" });
  }
  if (!permissionKeys.every((key) =>
    typeof key === "string" && allowedPermissions.has(key)
  )) {
    return response(400, { error: "invalid_permission_key" });
  }
  const uniquePermissionKeys = [...new Set(permissionKeys as string[])];

  // Only the active owner may create accounts and grant permissions.
  const { data: ownerMembership, error: ownerError } = await adminClient
    .from("business_members")
    .select("id")
    .eq("business_id", businessId)
    .eq("user_id", authData.user.id)
    .eq("is_owner", true)
    .eq("is_active", true)
    .maybeSingle();

  if (ownerError) {
    return response(500, { error: "owner_check_failed" });
  }
  if (!ownerMembership) {
    return response(403, { error: "owner_only" });
  }

  // Supabase sends an invitation email. SMTP/email delivery must be configured
  // in the Supabase project before this endpoint can be used by real customers.
  const { data: invited, error: inviteError } = await adminClient.auth.admin
    .inviteUserByEmail(email, {
      data: { display_name: displayName },
      redirectTo: Deno.env.get("INVITE_REDIRECT_URL"),
    });

  if (inviteError || !invited.user) {
    return response(400, {
      error: "invitation_failed",
      message: inviteError?.message ?? "No user was returned from invitation.",
    });
  }

  const { data: member, error: memberError } = await adminClient
    .from("business_members")
    .insert({
      business_id: businessId,
      user_id: invited.user.id,
      display_name: displayName,
      is_owner: false,
      is_active: true,
    })
    .select("id")
    .single();

  if (memberError || !member) {
    // The account was created by this invocation, so remove it if membership
    // creation fails rather than leaving an orphan account.
    await adminClient.auth.admin.deleteUser(invited.user.id);
    return response(500, { error: "member_creation_failed" });
  }

  if (uniquePermissionKeys.length > 0) {
    const { error: permissionError } = await adminClient
      .from("member_permissions")
      .insert(uniquePermissionKeys.map((permissionKey) => ({
        business_id: businessId,
        member_id: member.id,
        permission_key: permissionKey,
        allowed: true,
      })));

    if (permissionError) {
      await adminClient.from("business_members").delete().eq("id", member.id);
      await adminClient.auth.admin.deleteUser(invited.user.id);
      return response(500, { error: "permission_assignment_failed" });
    }
  }

  return response(201, {
    member_id: member.id,
    user_id: invited.user.id,
    email,
    display_name: displayName,
    permission_keys: uniquePermissionKeys,
    invitation_sent: true,
  });
});
