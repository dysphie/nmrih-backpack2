#include <sdktools>

/* Runs a VScript function that returns a string
 * 
 * @param entity		Entity to run the function on
 * @param buffer		String buffer to store result
 * @param maxlen		Buffer size
 * @param format		VScript function to run
 * @param ...			VScript function format parameters
 * @return              Number of non-null bytes written.
 * @error Invalid entity. Failure to create VScript proxy.
 */
stock int RunEntVScriptString(int entity, char[] buffer, int maxlen, const char[] format, any ...)
{
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	char original[64];
	GetEntPropString(index, Prop_Send, "m_iName", original, sizeof(original));

	char temp[1024];
	VFormat(temp, sizeof(temp), format, 5);
	Format(temp, sizeof(temp), "self.SetName(self.%s)", temp);

	SetVariantString(temp);
	AcceptEntityInput(index, "RunScriptCode", index, index);

	int bytes = GetEntPropString(index, Prop_Send, "m_iName", buffer, maxlen);
	SetEntPropString(index, Prop_Send, "m_iName", original);
	return bytes;
}

/* Runs a VScript function that returns a float
 * 
 * @param entity		Entity to run the function on
 * @param format		VScript function to run
 * @param ...			VScript function format parameters
 * @return              VScript function return
 * @error Invalid entity. Failure to create VScript proxy. Non-float return
 */
stock float RunEntVScriptFloat(int entity, const char[] format, any ...)
{
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	char original[64];
	GetEntPropString(index, Prop_Send, "m_iName", original, sizeof(original));

	char temp[1024];
	VFormat(temp, sizeof(temp), format, 3);
	Format(temp, sizeof(temp), "self.SetName(self.%s.tostring())", temp);

	SetVariantString(temp);
	AcceptEntityInput(index, "RunScriptCode", index, index);

	int len = GetEntPropString(index, Prop_Send, "m_iName", temp, sizeof(temp));
	SetEntPropString(index, Prop_Send, "m_iName", original);

	if (len > 0)
	{
		float result;
		if (StringToFloatEx(temp, result) == len) {
			return result;
		}
	}

	ThrowError("Bad function return. Expected int, got \"%s\" (%d bytes)", temp, len);
	return 0.0;
}

/* Runs a VScript function that returns an int
 * 
 * @param entity		Entity to run the function on
 * @param format		VScript function to run
 * @param ...			VScript function format parameters
 * @return              VScript function return
 * @error Invalid entity. Failure to create VScript proxy. Non-int return
 */
stock int RunEntVScriptInt(int entity, const char[] format, any ...)
{
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	char original[64];
	GetEntPropString(index, Prop_Send, "m_iName", original, sizeof(original));

	char temp[1024];
	VFormat(temp, sizeof(temp), format, 3);
	Format(temp, sizeof(temp), "self.SetName(self.%s.tostring())", temp);

	SetVariantString(temp);
	AcceptEntityInput(index, "RunScriptCode", index, index);

	int len = GetEntPropString(index, Prop_Send, "m_iName", temp, sizeof(temp));
	SetEntPropString(index, Prop_Send, "m_iName", original);

	if (len > 0)
	{
		int result;
		if (StringToIntEx(temp, result) == len) {
			return result;
		}
	}

	ThrowError("Bad function return. Expected int, got \"%s\" (%d bytes)", temp, len);
	return 0;
}

/* Runs a VScript function with void return
 * 
 * @param entity		Entity to run the function on
 * @param format		VScript function to run
 * @param ...			VScript function format parameters 
 * @noreturn
 * @error Invalid entity. Failure to create VScript proxy. Non-int return
 */
stock void RunEntVScript(int entity, const char[] format, any ...)
{
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	char temp[1024];
	VFormat(temp, sizeof(temp), format, 3);
	Format(temp, sizeof(temp), "self.%s", temp);

	SetVariantString(temp);
	AcceptEntityInput(index, "RunScriptCode", index, index);
}

/* Runs a VScript function that returns a vector
 * 
 * @param entity		Entity to run the function on
 * @param format		VScript function to run
 * @param ...			VScript function format parameters 
 * @noreturn
 * @error Invalid entity. Failure to create VScript proxy. Non-vector return
 */
stock void RunEntVScriptVector(int entity, float vec[3], const char[] format, any ...)
{
	int index = EntRefToEntIndex(entity);
	if (index == -1) {
		ThrowError("Entity %d (%d) is invalid", index, entity);
	}

	char original[64];
	GetEntPropString(index, Prop_Send, "m_iName", original, sizeof(original));

	char temp[1024];
	VFormat(temp, sizeof(temp), format, 4);
	Format(temp, sizeof(temp), "self.SetName(self.%s.ToKVString())", temp);
	SetVariantString(temp);
	AcceptEntityInput(index, "RunScriptCode", index, index);

	int len = GetEntPropString(index, Prop_Send, "m_iName", temp, sizeof(temp));
	SetEntPropString(index, Prop_Send, "m_iName", original);

	bool error;

	if (len > 0)
	{
		char strVec[3][11];

		int exploded = ExplodeString(temp, " ", strVec, 3, sizeof(strVec[]));
		if (exploded == 3)
		{
			float tempVec[3];
			for (int i; i < 3; i++) 
			{
				if (StringToFloatEx(strVec[i], tempVec[i]) != strlen(strVec[i])) 
				{
					error = true;
					break;
				}
			}

			if (!error) 
			{
				vec = tempVec;
				return;
			}
		}
	}

	ThrowError("Bad function return. Expected Vector, got \"%s\" (%d bytes)", temp, len);
}