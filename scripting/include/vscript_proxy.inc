#include <sdktools>

/* Runs a VScript function with void return
 * 
 * @param entity		Entity to run the code on
 * @param proxy			logic_script_proxy entity. If -1, one will be temporarily created
 * @error 				Invalid entity, VScript error or failure to create temporary proxy
 */
stock void RunEntVScript(int entity, const char[] code, int proxy = -1)
{
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	bool disposable;
	if (proxy == -1)
	{
		proxy = CreateEntityByName("logic_script_proxy");
		if (proxy == -1) {
			ThrowError("Failed to create disposable VScript proxy entity");
		}
		disposable = true;
	}
	else 
	{
		int proxy_index = EntRefToEntIndex(proxy);
		if (proxy_index == -1) {
			ThrowError("Entity %d (%d) is invalid", proxy_index, proxy);	
		}

		if (!HasEntProp(proxy_index, Prop_Data, "m_iReturnValue")) {
			ThrowError("Entity %d (%d) is not a logic_script_proxy", proxy_index, proxy);
		}
	}

	SetVariantString("!activator");
	AcceptEntityInput(proxy, "SetTargetEntity", index, index);

	SetVariantString(code);
	AcceptEntityInput(proxy, "RunFunction", index, index);

	if (GetEntProp(proxy, Prop_Data, "m_bError")) {
		ThrowError("VScript code failed");
	}

	if (disposable) {
		RemoveEntity(proxy);
	}
}

/* Runs a VScript function that returns a string
 * 
 * @param entity		Entity to run the code on
 * @param code			VScript code to run on the entity
 * @param buffer		String buffer to store result
 * @param maxlen		Buffer size
 * @param proxy			logic_script_proxy entity. If -1, one will be temporarily created
 * @return				Number of non-null bytes written.
 * @error 				Invalid entity, VScript error or failure to create temporary proxy
 */
stock int RunEntVScriptString(int entity, const char[] code, char[] buffer, int maxlen, int proxy = -1)
{
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	bool disposable;
	if (proxy == -1)
	{
		proxy = CreateEntityByName("logic_script_proxy");
		if (proxy == -1) {
			ThrowError("Failed to create disposable VScript proxy entity");
		}
		disposable = true;
	}
	else 
	{
		int proxy_index = EntRefToEntIndex(proxy);
		if (proxy_index == -1) {
			ThrowError("Entity %d (%d) is invalid", proxy_index, proxy);	
		}

		if (!HasEntProp(proxy_index, Prop_Data, "m_iReturnValue")) {
			ThrowError("Entity %d (%d) is not a logic_script_proxy", proxy_index, proxy);
		}
	}

	SetVariantString("!activator");
	AcceptEntityInput(proxy, "SetTargetEntity", index, index);

	SetVariantString(code);
	AcceptEntityInput(proxy, "RunFunctionString", index, index);
	
	if (GetEntProp(proxy, Prop_Data, "m_bError")) {
		ThrowError("VScript code failed");
	}
	
	int bytes = GetEntPropString(proxy, Prop_Data, "m_iszReturnValue", buffer, maxlen);

	if (disposable) {
		RemoveEntity(proxy);
	}

	return bytes;
}

/* Runs a VScript function that returns a bool
 * 
 * @param entity		Entity to run the code on
 * @param code			VScript code to run on the entity
 * @param proxy			logic_script_proxy entity. If -1, one will be temporarily created
 * @return				VScript function return
 * @error 				Invalid entity, VScript error or failure to create temporary proxy
 */
stock bool RunEntVScriptBool(int entity, const char[] code, int proxy = -1)
{
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	bool disposable;
	if (proxy == -1)
	{
		proxy = CreateEntityByName("logic_script_proxy");
		if (proxy == -1) {
			ThrowError("Failed to create disposable VScript proxy entity");
		}
		disposable = true;
	}
	else 
	{
		int proxy_index = EntRefToEntIndex(proxy);
		if (proxy_index == -1) {
			ThrowError("Entity %d (%d) is invalid", proxy_index, proxy);	
		}

		if (!HasEntProp(proxy_index, Prop_Data, "m_iReturnValue")) {
			ThrowError("Entity %d (%d) is not a logic_script_proxy", proxy_index, proxy);
		}
	}

	SetVariantString("!activator");
	AcceptEntityInput(proxy, "SetTargetEntity", index, index);

	SetVariantString(code);
	AcceptEntityInput(proxy, "RunFunctionBool", index, index);
	
	if (GetEntProp(proxy, Prop_Data, "m_bError")) {
		ThrowError("VScript code failed");
	}
	
	int result = GetEntProp(proxy, Prop_Data, "m_iReturnValue");

	if (disposable) {
		RemoveEntity(proxy);
	}

	return view_as<bool>(result);
}

/* Runs a VScript function that returns an int
 * 
 * @param entity		Entity to run the code on
 * @param code			VScript code to run on the entity
 * @param proxy			logic_script_proxy entity. If -1, one will be temporarily created
 * @return				VScript function return
 * @error 				Invalid entity, VScript error or failure to create temporary proxy
 */
stock int RunEntVScriptInt(int entity, const char[] code, int proxy = -1)
{
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	bool disposable;
	if (proxy == -1)
	{
		proxy = CreateEntityByName("logic_script_proxy");
		if (proxy == -1) {
			ThrowError("Failed to create disposable VScript proxy entity");
		}
		disposable = true;
	}
	else 
	{
		int proxy_index = EntRefToEntIndex(proxy);
		if (proxy_index == -1) {
			ThrowError("Entity %d (%d) is invalid", proxy_index, proxy);	
		}

		if (!HasEntProp(proxy_index, Prop_Data, "m_iReturnValue")) {
			ThrowError("Entity %d (%d) is not a logic_script_proxy", proxy_index, proxy);
		}
	}

	SetVariantString("!activator");
	AcceptEntityInput(proxy, "SetTargetEntity", index, index);

	SetVariantString(code);
	AcceptEntityInput(proxy, "RunFunctionInt", index, index);
	
	if (GetEntProp(proxy, Prop_Data, "m_bError")) {
		ThrowError("VScript code failed");
	}
	
	int result = GetEntProp(proxy, Prop_Data, "m_iReturnValue");

	if (disposable) {
		RemoveEntity(proxy);
	}

	return result;
}

/* Runs a VScript function that returns a float
 * 
 * @param entity		Entity to run the code on
 * @param code			VScript code to run on the entity
 * @param proxy			logic_script_proxy entity. If -1, one will be temporarily created
 * @return				VScript function return
 * @error 				Invalid entity, VScript error or failure to create temporary proxy
 */
stock float RunEntVScriptFloat(int entity, const char[] code, int proxy = -1)
{
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	bool disposable;
	if (proxy == -1)
	{
		proxy = CreateEntityByName("logic_script_proxy");
		if (proxy == -1) {
			ThrowError("Failed to create disposable VScript proxy entity");
		}
		disposable = true;
	}
	else 
	{
		int proxy_index = EntRefToEntIndex(proxy);
		if (proxy_index == -1) {
			ThrowError("Entity %d (%d) is invalid", proxy_index, proxy);	
		}

		if (!HasEntProp(proxy_index, Prop_Data, "m_iReturnValue")) {
			ThrowError("Entity %d (%d) is not a logic_script_proxy", proxy_index, proxy);
		}
	}

	SetVariantString("!activator");
	AcceptEntityInput(proxy, "SetTargetEntity", index, index);

	SetVariantString(code);
	AcceptEntityInput(proxy, "RunFunctionFloat", index, index);
	
	if (GetEntProp(proxy, Prop_Data, "m_bError")) {
		ThrowError("VScript code failed");
	}
	
	float result = GetEntPropFloat(proxy, Prop_Data, "m_flReturnValue");
	
	if (disposable) {
		RemoveEntity(proxy);
	}

	return result;
}

/* Runs a VScript function that returns a vector
 * 
 * @param entity		Entity to run the code on
 * @param code			VScript code to run on the entity
 * @param proxy			logic_script_proxy entity. If -1, one will be temporarily created
 * @error 				Invalid entity, VScript error or failure to create temporary proxy
 */
stock void RunEntVScriptVector(int entity, const char[] code, float vec[3], int proxy = -1)
{
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	bool disposable;
	if (proxy == -1)
	{
		proxy = CreateEntityByName("logic_script_proxy");
		if (proxy == -1) {
			ThrowError("Failed to create disposable VScript proxy entity");
		}
		disposable = true;
	}
	else 
	{
		int proxy_index = EntRefToEntIndex(proxy);
		if (proxy_index == -1) {
			ThrowError("Entity %d (%d) is invalid", proxy_index, proxy);	
		}

		if (!HasEntProp(proxy_index, Prop_Data, "m_iReturnValue")) {
			ThrowError("Entity %d (%d) is not a logic_script_proxy", proxy_index, proxy);
		}
	}

	SetVariantString("!activator");
	AcceptEntityInput(proxy, "SetTargetEntity", index, index);

	SetVariantString(code);
	AcceptEntityInput(proxy, "RunFunctionVector", index, index);
	
	if (GetEntProp(proxy, Prop_Data, "m_bError")) {
		ThrowError("VScript code failed");
	}
	
	GetEntPropVector(proxy, Prop_Data, "m_vecReturnValue", vec);

	if (disposable) {
		RemoveEntity(proxy);
	}
}

/* Runs a VScript function that returns an entity handle
 * 
 * @param entity		Entity to run the code on
 * @param code			VScript code to run on the entity
 * @param proxy			logic_script_proxy entity. If -1, one will be temporarily created
 * @return				VScript function return
 * @error 				Invalid entity, VScript error or failure to create temporary proxy
 */
stock int RunEntVScriptEnt(int entity, const char[] code, int proxy = -1)
{
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	bool disposable;
	if (proxy == -1)
	{
		proxy = CreateEntityByName("logic_script_proxy");
		if (proxy == -1) {
			ThrowError("Failed to create disposable VScript proxy entity");
		}
		disposable = true;
	}
	else 
	{
		int proxy_index = EntRefToEntIndex(proxy);
		if (proxy_index == -1) {
			ThrowError("Entity %d (%d) is invalid", proxy_index, proxy);	
		}

		if (!HasEntProp(proxy_index, Prop_Data, "m_iReturnValue")) {
			ThrowError("Entity %d (%d) is not a logic_script_proxy", proxy_index, proxy);
		}
	}

	SetVariantString("!activator");
	AcceptEntityInput(proxy, "SetTargetEntity", index, index);

	SetVariantString(code);
	AcceptEntityInput(proxy, "RunFunctionEHandle", index, index);
	
	if (GetEntProp(proxy, Prop_Data, "m_bError")) {
		ThrowError("VScript code failed");
	}
	
	int result = GetEntPropEnt(proxy, Prop_Data, "m_hReturnValue");

	if (disposable) {
		RemoveEntity(proxy);
	}

	return result;
}