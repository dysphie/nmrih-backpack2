#if defined _vscriptproxy_included_
  #endinput
#endif
#define _vscriptproxy_included_

#include <sdktools>


/* Runs a VScript function with void return
 * 
 * @param entity		Entity to run the code on
 * @param proxy			A logic_script_proxy entity, or INVALID_ENT_REFERENCE to use a global instance (recommended)
 * @error 				Invalid entity, VScript error or failure to create a temporary proxy
 */
stock void RunEntVScript(int entity, const char[] code, int proxy = -1)
{
	_RunEntVScriptShared(proxy, entity, code, "RunFunction");
}

/* Runs a VScript function that returns a string
 * 
 * @param entity		Entity to run the code on
 * @param code			VScript code to run on the entity
 * @param buffer		String buffer to store result
 * @param maxlen		Result buffer size
 * @param proxy			A logic_script_proxy entity, or INVALID_ENT_REFERENCE to use a global instance (recommended)
 * @return				Number of non-null bytes written.
 * @error 				Invalid entity, VScript error or failure to create a temporary proxy
 */
stock int RunEntVScriptString(int entity, const char[] code, char[] buffer, int maxlen, int proxy = -1)
{
	return GetEntPropString(
		_RunEntVScriptShared(proxy, entity, code, "RunFunctionString"), 
		Prop_Data, "m_iszReturnValue", buffer, maxlen);
}

/* Runs a VScript function that returns a bool
 * 
 * @param entity		Entity to run the code on
 * @param code			VScript code to run on the entity
 * @param proxy			A logic_script_proxy entity, or INVALID_ENT_REFERENCE to use a global instance (recommended)
 * @return				VScript function return
 * @error 				Invalid entity, VScript error or failure to create a temporary proxy
 */
stock bool RunEntVScriptBool(int entity, const char[] code, int proxy = -1)
{
	return GetEntProp(
		_RunEntVScriptShared(proxy, entity, code, "RunFunctionBool")
		, Prop_Data, "m_iReturnValue") != 0;
}

/* Runs a VScript function that returns an int
 * 
 * @param entity		Entity to run the code on
 * @param code			VScript code to run on the entity
 * @param proxy			A logic_script_proxy entity, or INVALID_ENT_REFERENCE to use a global instance (recommended)
 * @return				VScript function return
 * @error 				Invalid entity, VScript error or failure to create a temporary proxy
 */
stock int RunEntVScriptInt(int entity, const char[] code, int proxy = -1)
{
	return GetEntProp(
		_RunEntVScriptShared(proxy, entity, code, "RunFunctionInt"), 
		Prop_Data, "m_iReturnValue");
}

/* Runs a VScript function that returns a float
 * 
 * @param entity		Entity to run the code on
 * @param code			VScript code to run on the entity
 * @param proxy			A logic_script_proxy entity, or INVALID_ENT_REFERENCE to use a global instance (recommended)
 * @return				VScript function return
 * @error 				Invalid entity, VScript error or failure to create a temporary proxy
 */
stock float RunEntVScriptFloat(int entity, const char[] code, int proxy = -1)
{
	return GetEntPropFloat(
		_RunEntVScriptShared(proxy, entity, code, "RunFunctionFloat"), 
		Prop_Data, "m_flReturnValue");
}

/* Runs a VScript function that returns a vector
 * 
 * @param entity		Entity to run the code on
 * @param code			VScript code to run on the entity
 * @param proxy			A logic_script_proxy entity, or INVALID_ENT_REFERENCE to use a global instance (recommended)
 * @error 				Invalid entity, VScript error or failure to create a temporary proxy
 */
stock void RunEntVScriptVector(int entity, const char[] code, float vec[3], int proxy = -1)
{
	GetEntPropVector(
		_RunEntVScriptShared(proxy, entity, code, "RunFunctionVector"), 
		Prop_Data, "m_vecReturnValue", vec);
}

/* Runs a VScript function that returns an entity handle
 * 
 * @param entity		Entity to run the code on
 * @param code			VScript code to run on the entity
 * @param proxy			A logic_script_proxy entity, or INVALID_ENT_REFERENCE to use a global instance (recommended)
 * @return				VScript function return
 * @error 				Invalid entity, VScript error or failure to create a temporary proxy
 */
stock int RunEntVScriptEnt(int entity, const char[] code, int proxy = -1)
{
	return GetEntPropEnt(
		_RunEntVScriptShared(proxy, entity, code, "RunFunctionEHandle"), 
		Prop_Data, "m_hReturnValue");
}

/* Everything past this line is internal to this file */

static int _GetGlobalVScriptProxy()
{
	static int proxyRef = INVALID_ENT_REFERENCE;
	if (!IsValidEntity(proxyRef))
	{
		proxyRef = FindEntityByClassname(-1, "logic_script_proxy");
		if (proxyRef == INVALID_ENT_REFERENCE)
		{
			proxyRef = CreateEntityByName("logic_script_proxy");
			if (proxyRef == -1) {
				ThrowError("Failed to create persistent VScript proxy entity");
			}
		}
	}

	return proxyRef;
}

static int _RunEntVScriptShared(int proxy, int entity, const char[] code, const char[] input)
{
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	if (proxy == -1)
	{
		proxy = _GetGlobalVScriptProxy();
		if (!IsValidEntity(proxy))
		{
			ThrowError("Failed to get persistent VScript proxy entity");
		}
	}

	SetVariantString("!activator");
	AcceptEntityInput(proxy, "SetTargetEntity", index, index);

	SetVariantString(code);
	AcceptEntityInput(proxy, input, index, index);
	
	if (GetEntProp(proxy, Prop_Data, "m_bError")) {
		ThrowError("VScript code failed, check Squirrel VM output");
	}

	return proxy;
}