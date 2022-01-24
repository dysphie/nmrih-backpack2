#include <sdktools>

/* Runs a VScript function with void return
 * 
 * @param proxy			Reference to logic_script_proxy entity
 * @param entity		Entity to run the function on
 * @param format		VScript function to run
 * @param ...			VScript function format parameters 
 * @noreturn
 * @error Invalid entity. Failure to create VScript proxy. Non-int return
 */
stock void RunEntVScript(int proxy, int entity, const char[] format, any ...)
{
	if (!IsValidEntity(proxy)) {
		ThrowError("Invalid script proxy (%d)", proxy);
	}
	
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	SetVariantString("!activator");
	AcceptEntityInput(proxy, "SetTargetEntity", entity, entity);

	char temp[1024];
	VFormat(temp, sizeof(temp), format, 4);

	SetVariantString(temp);
	AcceptEntityInput(proxy, "RunFunction", entity, entity);

	bool bFailure = (GetEntProp(proxy, Prop_Data, "m_bError") != 0) ? true : false;
	if (bFailure) {
		ThrowError("VScript proxy failed");
	}
}

/* Runs a VScript function that returns a string
 * 
 * @param proxy			Reference to logic_script_proxy entity
 * @param entity		Entity to run the function on
 * @param buffer		String buffer to store result
 * @param maxlen		Buffer size
 * @param format		VScript function to run
 * @param ...			VScript function format parameters
 * @return              Number of non-null bytes written.
 * @error Invalid entity. Failure to create VScript proxy.
 */
stock int RunEntVScriptString(int proxy, int entity, char[] buffer, int maxlen, const char[] format, any ...)
{
	if (!IsValidEntity(proxy)) {
		ThrowError("Invalid script proxy (%d)", proxy);
	}
	
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	SetVariantString("!activator");
	AcceptEntityInput(proxy, "SetTargetEntity", entity, entity);

	char temp[1024];
	VFormat(temp, sizeof(temp), format, 6);

	SetVariantString(temp);
	AcceptEntityInput(proxy, "RunFunctionString", entity, entity);
	
	bool bFailure = (GetEntProp(proxy, Prop_Data, "m_bError") != 0) ? true : false;
	if (bFailure) {
		ThrowError("VScript proxy failed");
	}
	
	int bytes = GetEntPropString(proxy, Prop_Data, "m_iszReturnValue", buffer, maxlen);
	return bytes;
}

/* Runs a VScript function that returns an int
 * 
 * @param proxy			Reference to logic_script_proxy entity
 * @param entity		Entity to run the function on
 * @param format		VScript function to run
 * @param ...			VScript function format parameters
 * @return              VScript function return
 * @error Invalid entity. Failure to create VScript proxy. Non-int return
 */
stock int RunEntVScriptInt(int proxy, int entity, const char[] format, any ...)
{
	if (!IsValidEntity(proxy)) {
		ThrowError("Invalid script proxy (%d)", proxy);
	}
	
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	SetVariantString("!activator");
	AcceptEntityInput(proxy, "SetTargetEntity", entity, entity);

	char temp[1024];
	VFormat(temp, sizeof(temp), format, 4);

	SetVariantString(temp);
	AcceptEntityInput(proxy, "RunFunctionInt", entity, entity);
	
	bool bFailure = (GetEntProp(proxy, Prop_Data, "m_bError") != 0) ? true : false;
	if (bFailure) {
		ThrowError("VScript proxy failed");
	}
	
	return GetEntProp(proxy, Prop_Data, "m_iReturnValue");
}

/* Runs a VScript function that returns a float
 * 
 * @param proxy			Reference to logic_script_proxy entity
 * @param entity		Entity to run the function on
 * @param format		VScript function to run
 * @param ...			VScript function format parameters
 * @return              VScript function return
 * @error Invalid entity. Failure to create VScript proxy. Non-float return
 */
stock float RunEntVScriptFloat(int proxy, int entity, const char[] format, any ...)
{
	if (!IsValidEntity(proxy)) {
		ThrowError("Invalid script proxy (%d)", proxy);
	}
	
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	SetVariantString("!activator");
	AcceptEntityInput(proxy, "SetTargetEntity", entity, entity);

	char temp[1024];
	VFormat(temp, sizeof(temp), format, 4);

	SetVariantString(temp);
	AcceptEntityInput(proxy, "RunFunctionFloat", entity, entity);
	
	bool bFailure = (GetEntProp(proxy, Prop_Data, "m_bError") != 0) ? true : false;
	if (bFailure) {
		ThrowError("VScript proxy failed");
	}
	
	return GetEntPropFloat(proxy, Prop_Data, "m_flReturnValue");
}

/* Runs a VScript function that returns a vector
 * 
 * @param proxy			Reference to logic_script_proxy entity
 * @param entity		Entity to run the function on
 * @param format		VScript function to run
 * @param ...			VScript function format parameters 
 * @noreturn
 * @error Invalid entity. Failure to create VScript proxy. Non-vector return
 */
stock void RunEntVScriptVector(int proxy, int entity, float vec[3], const char[] format, any ...)
{
	if (!IsValidEntity(proxy)) {
		ThrowError("Invalid script proxy (%d)", proxy);
	}
	
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	SetVariantString("!activator");
	AcceptEntityInput(proxy, "SetTargetEntity", entity, entity);

	char temp[1024];
	VFormat(temp, sizeof(temp), format, 5);

	SetVariantString(temp);
	AcceptEntityInput(proxy, "RunFunctionVector", entity, entity);
	
	bool bFailure = (GetEntProp(proxy, Prop_Data, "m_bError") != 0) ? true : false;
	if (bFailure) {
		ThrowError("VScript proxy failed");
	}
	
	GetEntPropVector(proxy, Prop_Data, "m_vecReturnValue", vec);
}
