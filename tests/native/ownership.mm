#include "4DPluginAPI.h"
#include "PrivateTypes.h"
#include "EntryPoints.h"

#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <objc/runtime.h>

static NSString *syntheticInternal;
static NSString *syntheticDisplay;

@interface OwnershipFixtureFont : NSObject
@end
@implementation OwnershipFixtureFont
- (NSString *)displayName { return syntheticDisplay; }
- (NSString *)fontName { return syntheticInternal; }
- (NSArray *)availableFonts { return [NSArray arrayWithObject:syntheticInternal]; }
@end

static id fixtureFont(id, SEL, NSString *name, CGFloat)
{
	if([name isEqualToString:syntheticInternal])
		return [[[OwnershipFixtureFont alloc] init] autorelease];
	return nil;
}

static id fixtureManager(id, SEL)
{
	return [[[OwnershipFixtureFont alloc] init] autorelease];
}

namespace {
struct Picture {
	int refs;
	std::vector<uint8_t> bytes;
};

std::map<PA_Unichar *, size_t> strings;
std::map<PA_Handle, size_t> handles;
std::map<PA_Picture, Picture *> pictures;
bool allocatedEmpty = true;
bool failNextHandle = false;
bool nullNextHandleData = false;
bool failCommand = false;
int commandReturn = 0;
int commandCalls = 0;
CUTF16String expectedPath;
CUTF16String expectedFormat;

void require(bool condition, const char *message)
{
	if(!condition) {
		std::cerr << "FAIL: " << message << "\n";
		std::abort();
	}
}

PA_Unistring makeString(const PA_Unichar *text)
{
	const size_t length = text ? std::char_traits<PA_Unichar>::length(text) : 0;
	PA_Unistring result = {};
	if(length || allocatedEmpty) {
		result.fString = static_cast<PA_Unichar *>(std::malloc((length + 1) * sizeof(PA_Unichar)));
		require(result.fString != NULL, "fixture string allocation");
		if(length) std::memcpy(result.fString, text, length * sizeof(PA_Unichar));
		result.fString[length] = 0;
		PA_Unichar *buffer = result.fString;
		strings[buffer] = length;
	}
	result.fLength = static_cast<PA_long32>(length);
	return result;
}

CUTF16String readString(PA_Unistring string)
{
	PA_Unichar *buffer = string.fString;
	if(!buffer) {
		require(string.fLength == 0, "null string must be empty");
		return CUTF16String();
	}
	require(strings.count(buffer) == 1, "string is live");
	require(strings.at(buffer) == static_cast<size_t>(string.fLength), "UTF16 length excludes terminator");
	require(string.fString[string.fLength] == 0, "UTF16 terminator");
	return CUTF16String(string.fString, string.fLength);
}

void disposeString(PA_Unistring string)
{
	PA_Unichar *buffer = string.fString;
	if(buffer) {
		require(strings.erase(buffer) == 1, "path-string-double-dispose / invalid string owner");
		std::free(buffer);
	}
}

PA_Picture makePicture(const void *bytes, size_t length)
{
	Picture *picture = new Picture;
	picture->refs = 1;
	if(length) {
		const uint8_t *begin = static_cast<const uint8_t *>(bytes);
		picture->bytes.assign(begin, begin + length);
	}
	pictures[picture] = picture;
	return picture;
}

void releasePicture(PA_Picture value)
{
	if(value) {
		require(pictures.count(value) == 1, "picture is live on release");
		Picture *picture = pictures.at(value);
		require(picture->refs > 0, "positive picture refcount");
		if(--picture->refs == 0) {
			pictures.erase(value);
			delete picture;
		}
	}
}

void clearVariable(PA_Variable *variable)
{
	require(variable->fType != 0, "raw-kind-zero command failure sentinel is not an owner");
	switch(variable->fType) {
		case eVK_Unistring:
			disposeString(variable->uValue.fString);
			break;
		case eVK_Picture:
			releasePicture(variable->uValue.fPicture);
			break;
		case eVK_ArrayUnicode: {
			PA_Handle handle = variable->uValue.fArray.fData;
			if(handle) {
				require(handles.count(handle) == 1, "array handle is live");
				PA_Unistring *elements = reinterpret_cast<PA_Unistring *>(*handle);
				for(PA_long32 i = 0; i <= variable->uValue.fArray.fNbElements; ++i)
					disposeString(elements[i]);
				PA_DisposeHandle(handle);
			}
			break;
		}
		case eVK_Undefined:
		case eVK_Longint:
		case eVK_Real:
		case eVK_Time:
		case eVK_Date:
		case eVK_Boolean:
			break;
		default:
			require(false, "unmodeled variable cleanup");
	}
	*variable = {};
	variable->fType = eVK_Undefined;
}

void replacePicture(PA_Variable *variable, PA_Picture value)
{
	clearVariable(variable);
	PA_SetPictureVariable(variable, value);
}

void command(EngineBlock *eb)
{
	++commandCalls;
	PA_Variable **args = static_cast<PA_Variable **>(eb->fPtr1);
	PA_Variable *result = static_cast<PA_Variable *>(eb->fPtr2);
	if(failCommand) {
		eb->fError = eER_IncompatibleTypes;
		return;
	}
	switch(eb->fParam1) {
		case 678: {
			require(readString(args[0]->uValue.fString) == expectedPath, "exact synchronous path");
			const uint8_t data[] = {7, 8, 9};
			replacePicture(args[1], makePicture(data, sizeof(data)));
			break;
		}
		case 1002:
			require(readString(args[1]->uValue.fString) == expectedFormat, "exact converted format");
			require(pictures.count(static_cast<PA_Picture>(args[0]->uValue.fPicture)) == 1, "copy input picture alive");
			break;
		case 988:
			require(PA_GetLongintVariable(*args[1]) == 101, "grayscale transform");
			require(pictures.count(static_cast<PA_Picture>(args[0]->uValue.fPicture)) == 1, "grayscale input alive");
			break;
		case 457:
			require(pictures.count(static_cast<PA_Picture>(args[0]->uValue.fPicture)) == 1, "properties borrowed input alive");
			PA_SetLongintVariable(args[1], 23);
			PA_SetLongintVariable(args[2], 17);
			break;
		case 679: {
			require(pictures.count(static_cast<PA_Picture>(args[0]->uValue.fPicture)) == 1, "thumbnail borrowed input alive");
			require(PA_GetLongintVariable(*args[2]) == 3 && PA_GetLongintVariable(*args[3]) == 4,
					"thumbnail dimensions");
			const uint8_t data[] = {3, 4};
			replacePicture(args[1], makePicture(data, sizeof(data)));
			break;
		}
		default:
			require(false, "unexpected command");
	}
	if(commandReturn == 1) {
		PA_Unichar text[] = {'r', 0x65e5, 0xd83d, 0xde00, 0};
		PA_Unistring string = makeString(text);
		PA_SetStringVariable(result, &string);
	} else if(commandReturn == 2) {
		PA_SetPictureVariable(result, makePicture(NULL, 0));
	}
}

void engine(short selector, EngineBlock *eb)
{
	switch(selector) {
		case EX_CREATE_UNISTRING:
			eb->fUniString1 = makeString(reinterpret_cast<PA_Unichar *>(eb->fHandle));
			break;
		case EX_DISPOSE_UNISTRING:
			disposeString(eb->fUniString1);
			break;
		case EX_SET_UNISTRING: {
			PA_Unistring copy = makeString(reinterpret_cast<PA_Unichar *>(eb->fHandle));
			disposeString(eb->fUniString1);
			eb->fUniString1 = copy;
			break;
		}
		case EX_CREATE_PICTURE:
			eb->fPicture = makePicture(eb->fPtr1, eb->fParam1);
			eb->fError = eER_NoErr;
			break;
		case EX_DISPOSE_PICTURE:
			releasePicture(eb->fPicture);
			break;
		case EX_DUPLICATE_PICTURE: {
			PA_Picture value = eb->fPicture;
			if(value) {
				require(pictures.count(value) == 1, "retain a live picture");
				Picture *picture = pictures.at(value);
				if(eb->fParam1 == 0) ++picture->refs;
				else eb->fPicture = makePicture(picture->bytes.data(), picture->bytes.size());
			}
			break;
		}
		case EX_GET_PICTURE_DATA:
			// Failure does not promise a valid output descriptor. No ownership claim
			// is made here for successful picture-data metadata.
			std::memset(&eb->fUniString1, 0xa5, sizeof(eb->fUniString1));
			eb->fError = eER_IncompatibleTypes;
			break;
		case EX_CLEAR_VARIABLE:
			clearVariable(static_cast<PA_Variable *>(eb->fPtr1));
			break;
		case EX_HANDLE_MANAGER: {
			eb->fError = eER_NoErr;
			if(eb->fParam1 == 1) {
				if(failNextHandle) {
					failNextHandle = false;
					eb->fHandle = NULL;
					eb->fError = eER_IncompatibleTypes;
					break;
				}
				PA_Handle handle = static_cast<PA_Handle>(std::malloc(sizeof(char *)));
				*handle = nullNextHandleData ? NULL :
					static_cast<char *>(std::calloc(1, eb->fParam2 ? eb->fParam2 : 1));
				nullNextHandleData = false;
				handles[handle] = eb->fParam2;
				eb->fHandle = handle;
			} else {
				PA_Handle value = eb->fHandle;
				if(!value && (eb->fParam1 == 5 || eb->fParam1 == 6)) {
					eb->fParam3 = 0;
					eb->fError = eER_IncompatibleTypes;
					break;
				}
				require(handles.count(value) == 1, "handle is live");
				switch(eb->fParam1) {
					case 2:
						handles.erase(value);
						std::free(*eb->fHandle);
						std::free(eb->fHandle);
						break;
					case 3: {
						const size_t old = handles.at(value);
						const size_t size = eb->fParam2;
						*eb->fHandle = static_cast<char *>(std::realloc(*eb->fHandle, size ? size : 1));
						require(*eb->fHandle != NULL, "fixture handle resize");
						if(size > old) std::memset(*eb->fHandle + old, 0, size - old);
						handles[value] = size;
						break;
					}
					case 4: eb->fParam2 = handles.at(value); break;
					case 5: eb->fParam3 = reinterpret_cast<sLONG_PTR>(*eb->fHandle); break;
					case 6: break;
					default: require(false, "unmodeled handle operation");
				}
			}
			break;
		}
		case EX_CONVERT_CHARSET_TO_CHARSET: {
			const CFStringEncoding from = eb->fParam2 == eVTC_UTF_8 ?
				kCFStringEncodingUTF8 : kCFStringEncodingUTF16LE;
			const CFStringEncoding to = eb->fParam4 == eVTC_UTF_8 ?
				kCFStringEncodingUTF8 : kCFStringEncodingUTF16LE;
			CFStringRef text = CFStringCreateWithBytes(NULL, static_cast<const UInt8 *>(eb->fPtr1),
													 eb->fParam1, from, false);
			require(text != NULL, "valid charset input");
			CFIndex used = 0;
			const CFIndex count = CFStringGetLength(text);
			const CFIndex converted = CFStringGetBytes(text, CFRangeMake(0, count), to, 0, false,
													  static_cast<UInt8 *>(eb->fPtr2), eb->fParam3, &used);
			require(converted == count, "charset destination capacity in bytes");
			// No added terminator and no units substitution: SDK returns bytes.
			eb->fParam3 = used;
			eb->fError = eER_NoErr;
			CFRelease(text);
			break;
		}
		case EX_EXECUTE_COMMAND_BY_ID:
			command(eb);
			break;
		default:
			require(false, "unmodeled engine selector");
	}
}

CUTF16String fixture(const char *name)
{
	if(std::strcmp(name, "png") == 0 || std::strcmp(name, "jpg") == 0 || std::strcmp(name, "tif") == 0) {
		CUTF16String text;
		text.push_back('.');
		for(const char *p = name; *p; ++p) text.push_back(*p);
		return text;
	}
	if(std::strcmp(name, "ascii") == 0) {
		PA_Unichar text[] = {'A', 'b', '.', 'p', 'n', 'g', 0};
		return CUTF16String(text);
	}
	if(std::strcmp(name, "bmp") == 0) {
		PA_Unichar text[] = {0x65e5, 0x672c, 0x00e9, 0};
		return CUTF16String(text);
	}
	if(std::strcmp(name, "supplementary") == 0) {
		PA_Unichar text[] = {'A', 0xd83d, 0xde00, 'Z', 0};
		return CUTF16String(text);
	}
	return CUTF16String();
}

void balance()
{
	require(strings.empty(), "string-owner-balance (including initial empty owners and command returns)");
	require(handles.empty(), "handle-owner-balance");
	require(pictures.empty(), "picture-reference-balance (initial empties, outputs and temporaries)");
}

void pictureCase(const char *name, const CUTF16String &text)
{
	const uint8_t bytes[] = {1, 2, 3, 4};
	{
		CPicture picture;
		if(std::strcmp(name, "set-bytes") == 0) {
			picture.setBytes(bytes, sizeof(bytes));
			picture.setBytes(bytes, sizeof(bytes));
			require(pictures.at(picture.getPicture())->bytes == std::vector<uint8_t>(bytes, bytes + 4),
					"setBytes exact payload");
		} else if(std::strcmp(name, "path") == 0) {
			expectedPath = text;
			C_TEXT path;
			path.setUTF16String(text.c_str(), text.size());
			CUTF8String utf8;
			path.copyUTF8String(&utf8);
			picture.fromFileAtPath(&utf8);
			if(!failCommand && commandCalls)
				require(pictures.at(picture.getPicture())->bytes == std::vector<uint8_t>({7, 8, 9}),
						"file output retained after argument cleanup");
		} else if(std::strcmp(name, "copy") == 0) {
			expectedFormat = text;
			C_TEXT format;
			format.setUTF16String(text.c_str(), text.size());
			CUTF8String utf8;
			format.copyUTF8String(&utf8);
			utf8.push_back(0);
			PA_Picture copy = picture.createCopy(reinterpret_cast<const char *>(utf8.c_str()));
			require(pictures.count(copy) == 1, "copy owning handoff survives argument cleanup");
			PA_DisposePicture(copy);
		} else if(std::strcmp(name, "grayscale") == 0) {
			PA_Picture copy = picture.createGrayScale();
			require(pictures.count(copy) == 1, "grayscale owning handoff");
			PA_DisposePicture(copy);
		} else if(std::strcmp(name, "properties") == 0) {
			unsigned int width = 0, height = 0;
			picture.getSize(&width, &height);
			if(!failCommand && commandCalls) require(width == 23 && height == 17, "exact properties");
			require(pictures.at(picture.getPicture())->refs == 1, "borrowed input detached, not released");
		} else if(std::strcmp(name, "thumbnail") == 0) {
			PA_Picture copy = picture.createThumbnail(3, 4);
			require(pictures.count(copy) == 1, "thumbnail owning handoff");
			PA_DisposePicture(copy);
			require(pictures.at(picture.getPicture())->refs == 1, "thumbnail input detached");
		} else {
			require(false, "unknown picture test");
		}
	}
	balance();
}

void arrayCase(bool reject, const CUTF16String &text)
{
	PA_Variable output = PA_CreateVariable(eVK_Undefined);
	BytePtr parameter = reinterpret_cast<BytePtr>(&output);
	ARRAY_TEXT source;
	source.appendUTF16String(text.c_str(), text.size());
	source.appendUTF16String(text.c_str(), text.size());
	if(reject) {
		failNextHandle = true;
		bool threw = false;
		try { source.toParamAtIndex(&parameter, 1); }
		catch(const std::runtime_error &) { threw = true; }
		require(threw, "rejected-array-storage must report failure, not publish success");
		require(output.fType == eVK_Undefined, "rejected destination not published");
	} else {
		source.toParamAtIndex(&parameter, 1);
		for(int i = 0; i < 128; ++i) {
			PA_Unistring churn = PA_CreateUnistring(const_cast<PA_Unichar *>(text.c_str()));
			PA_DisposeUnistring(&churn);
		}
		require(readString(PA_GetStringInArray(output, 0)) == text, "array zero exact text");
		require(readString(PA_GetStringInArray(output, 1)) == text, "array one exact text");
		if(!text.empty())
			require(PA_GetStringInArray(output, 0).fString != PA_GetStringInArray(output, 1).fString,
					"independent output allocations");
		ARRAY_TEXT copied;
		copied.fromParamAtIndex(&parameter, 1);
		CUTF16String replacement = text;
		replacement.push_back('!');
		source.setUTF16StringAtIndex(&replacement, 0);
		source.setSize(1);
		source.toParamAtIndex(&parameter, 1);
		require(readString(PA_GetStringInArray(output, 0)) == replacement, "replacement exact text after shrink");
		PA_ClearVariable(&output);
		// Borrowed input was copied before replacement/shrink/clear.
		CUTF16String saved;
		copied.copyUTF16StringAtIndex(&saved, 1);
		require(saved == text, "borrowed array copied before mutation");
		copied.toParamAtIndex(&parameter, 1);
		require(readString(PA_GetStringInArray(output, 1)) == text, "copy survives source clear");
		PA_ClearVariable(&output);
	}
	balance();
}

void setterRejections(const CUTF16String &text)
{
	PA_Variable array = PA_CreateVariable(eVK_ArrayUnicode);
	PA_Unistring owned = PA_CreateUnistring(const_cast<PA_Unichar *>(text.c_str()));
	PA_Variable wrongType = PA_CreateVariable(eVK_Longint);
	PA_SetStringInArray(wrongType, 0, &owned);
	PA_Variable missing = array;
	missing.uValue.fArray.fData = NULL;
	PA_SetStringInArray(missing, 0, &owned);
	PA_SetStringInArray(array, -1, &owned);
	PA_SetStringInArray(array, 1, &owned);
	PA_SetStringInArray(array, 0, NULL);
	require(readString(owned) == text, "rejected setters retain caller ownership");
	PA_DisposeUnistring(&owned);
	PA_ClearVariable(&array);
	balance();
}

void wrapperRejections(const CUTF16String &text)
{
	ARRAY_TEXT source;
	source.appendUTF16String(text.c_str(), text.size());
	PA_Variable output = PA_CreateVariable(eVK_Longint);
	BytePtr parameter = reinterpret_cast<BytePtr>(&output);
	PA_SetLongintVariable(&output, 123);
	source.toParamAtIndex(&parameter, 1);
	require(output.fType == eVK_Longint && PA_GetLongintVariable(output) == 123,
			"wrong-type wrapper output unchanged");
	require(strings.empty() && handles.empty(), "wrong-type wrapper allocates nothing");
	output = PA_CreateVariable(eVK_Undefined);
	nullNextHandleData = true;
	bool threw = false;
	try { source.toParamAtIndex(&parameter, 1); }
	catch(const std::runtime_error &) { threw = true; }
	require(threw && output.fType == eVK_Undefined, "null-data new array rejected without publication");
	balance();
	output.fType = eVK_ArrayUnicode;
	output.uValue.fArray.fData = NULL;
	output.uValue.fArray.fNbElements = 0;
	threw = false;
	try { source.toParamAtIndex(&parameter, 1); }
	catch(const std::runtime_error &) { threw = true; }
	require(threw, "existing missing-data array reports rejection");
	balance();
}

void scalarCase(const CUTF16String &text)
{
	PA_Unistring input = PA_CreateUnistring(const_cast<PA_Unichar *>(text.c_str()));
	PA_Unistring result = PA_CreateUnistring(NULL);
	BytePtr parameter = reinterpret_cast<BytePtr>(&input);
	{
		C_TEXT copy;
		copy.fromParamAtIndex(&parameter, 1);
		PA_DisposeUnistring(&input);
		PA_Unistring *resultPointer = &result;
		copy.setReturn(reinterpret_cast<sLONG_PTR *>(&resultPointer));
		require(readString(result) == text, "scalar result content copied");
	}
	require(readString(result) == text, "scalar result survives wrapper destruction");
	PA_DisposeUnistring(&result);
	balance();
}

void dispatcherCase(const CUTF16String &text)
{
	// Replace only font lookup/enumeration. Production dispatcher and text
	// wrappers still run, without reading installed fonts or opening UI.
	PA_Unichar internal[] = {'P', 'S', '-', 'f', 'i', 'x', 't', 'u', 'r', 'e', 0};
	syntheticInternal = [[NSString alloc] initWithCharacters:internal length:10];
	syntheticDisplay = [[NSString alloc] initWithCharacters:text.c_str() length:text.size()];
	Method font = class_getClassMethod([NSFont class], @selector(fontWithName:size:));
	Method manager = class_getClassMethod([NSFontManager class], @selector(sharedFontManager));
	IMP oldFont = method_setImplementation(font, reinterpret_cast<IMP>(fixtureFont));
	IMP oldManager = method_setImplementation(manager, reinterpret_cast<IMP>(fixtureManager));
	PackInitBlock init = {};
	init.fCall4Dex = engine;
	FourDPackex(kInitPlugin, &init, NULL, NULL);
	require(init.fSupportedVersion == 0x00001400 && gCall4D == engine, "actual exported entry initialization");
	for(int direction = 0; direction < 2; ++direction) {
		PA_Unistring input = PA_CreateUnistring(direction ? const_cast<PA_Unichar *>(text.c_str()) : internal);
		PA_Unistring output = PA_CreateUnistring(NULL);
		PA_Unistring *outputPointer = &output;
		BytePtr parameters[] = {reinterpret_cast<BytePtr>(&input), reinterpret_cast<BytePtr>(&direction)};
		FourDPackex(1, parameters, NULL, &outputPointer);
		const CUTF16String expected = direction ? CUTF16String(internal) : text;
		require(readString(output) == expected, "actual dispatcher exact synthetic result");
		PA_DisposeUnistring(&input);
		require(readString(output) == expected, "dispatcher independent result survives input disposal");
		PA_DisposeUnistring(&output);
	}
	method_setImplementation(font, oldFont);
	method_setImplementation(manager, oldManager);
	[syntheticInternal release];
	[syntheticDisplay release];
	balance();
}
}

int main(int argc, char **argv)
{
	require(argc == 7, "scenario fixture allocated-empty return-kind fail-command fail-handle");
	gCall4D = engine;
	allocatedEmpty = std::strcmp(argv[3], "1") == 0;
	commandReturn = std::atoi(argv[4]);
	failCommand = std::strcmp(argv[5], "1") == 0;
	const bool failHandle = std::strcmp(argv[6], "1") == 0;
	const CUTF16String text = fixture(argv[2]);
	@autoreleasepool {
		if(std::strcmp(argv[1], "array") == 0) arrayCase(false, text);
		else if(std::strcmp(argv[1], "reject-array") == 0) arrayCase(true, text);
		else if(std::strcmp(argv[1], "setter-rejections") == 0) setterRejections(text);
		else if(std::strcmp(argv[1], "wrapper-rejections") == 0) wrapperRejections(text);
		else if(std::strcmp(argv[1], "scalar") == 0) scalarCase(text);
		else if(std::strcmp(argv[1], "dispatcher") == 0) dispatcherCase(text);
		else {
			// CPicture construction itself needs no handles.
			failNextHandle = failHandle;
			pictureCase(argv[1], text);
			if(failHandle) require(commandCalls == 0, "command handle failure did not call engine");
		}
	}
	std::cout << "PASS " << argv[1] << "/" << argv[2] << "\n";
}
