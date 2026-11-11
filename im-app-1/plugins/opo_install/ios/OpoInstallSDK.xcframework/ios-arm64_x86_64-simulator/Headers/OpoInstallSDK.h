
#import <Foundation/Foundation.h>
#import "OpoInstallData.h"
#import "OpoInstallSharePlatform.h"

/**
 * Conform to this protocol to allow getting data about wakeup attribution
 */
@protocol OpoInstallDelegate<NSObject>

@optional

/**
 * Gets h5 page dynamic parameters on wake up
 * @param appData Dynamic parameter object(can be empty).
 */
- (void)getWakeUpParams:(nullable OpoInstallData *)appData;

@end

@interface OpoInstallSDK : NSObject

/**
 * Gets the sdk version number
 */
+ (NSString *_Nullable)sdkVersion;


/**
 * Sets debug mode, controlling SDK debug-level log output.
 * By default debug logs are enabled in Debug builds and disabled in Release builds;
 * calling this method explicitly overrides the default. Error and Warning logs are always printed.
 * @param enabled Whether to enable debug-level logging.
 */
+(void)setDebug:(BOOL)enabled;


/**
 * Gets the singleton instance of OpoInstallSDK.
 */
+(instancetype _Nullable)defaultManager;


///-------------
/// @name Some methods of initializations
///-------------

/**
 * Initializes the sdk method,for h5 attribution only.
 * @param delegate See 'OpoInstallDelegate'.
 */
+(void)initWithDelegate:(id<OpoInstallDelegate> _Nonnull)delegate;


/**
 * Initializes the sdk and pass in the IDFA.One of the initializing ways to implement AD attribution. (optional)
 *
 * @param adid IDFA
 * @param delegate See 'OpoInstallDelegate'.
 * @discussion 1.Only users who need to use the "Advertising Platform Channel" for advertising performance monitoring need to call.  2.Need to turn on the background switch, location: "iOS integration "->"iOS Application Configuration "->" AD Platform docking".
 * ***Please check the detailed documentation：https://www.opoinstall.com/docs?doc=ios-sdk-guide***
 */
+ (void)initWithDelegate:(nullable id<OpoInstallDelegate>)delegate advertisingId:(NSString *_Nullable)adid;



///----------------------
/// @name Gets the dynamic parameters of the installation
///----------------------


/**
 * @param completedBlock Callback block, will be called back in the main thread (UI thread).
 *
 * @discussion
 * Do not save the dynamic installation parameters yourself, call this method to get them every time you need them
 * ***referenced document: https://www.opoinstall.com/docs?doc=ios-sdk-faq***
 */
-(void)getInstallParmsCompleted:(void (^_Nullable)(OpoInstallData*_Nullable appData))completedBlock;


/**
 * When the developer needs to obtain the "dynamic parameters" transmitted by the web page after the user installs the app (such as invitation code, game room number, channel number etc.), the method can return the data in the first time.
 *
 * @param timeoutInterval The callback timeout duration can be set, in seconds.
 * @param completedBlock Callback block, will be called back in the main thread (UI thread).
 */
-(void)getInstallParmsWithTimeoutInterval:(NSTimeInterval)timeoutInterval
                                completed:(void (^_Nullable)(OpoInstallData*_Nullable appData))completedBlock;



///---------------------
/// @name The callback method for jumping from web to app is set in the scheme or universal links callback method of the system.
///---------------------

/**
 * Processing URI schemes.
 * @param URL URL returned by the system callback.
 * @return BOOL Whether it is recognized by the sdk.
 */
+(BOOL)handLinkURL:(NSURL *_Nullable)URL;


/**
 * 处理 通用链接
 * @param userActivity The userActivity returned in the universal links system callback.
 * @return BOOL Whether it is recognized by the sdk.
 */
+(BOOL)continueUserActivity:(NSUserActivity *_Nullable)userActivity;



///--------------
/// @name Statistically relevant methods.
///--------------

/**
 * Method for counting registrations.
 *
 * @discussion This method must be called after the registration is successful to avoid repeated calls.
 */
+(void)reportRegister;

/**
 * Channel effect statistics.
 *
 * Currently, the SDK adopts the periodic reporting policy, and the interval is controlled by the server.
 * Statistics of user payment consumption, click times, etc.
 *
 * @param effectID Effect point id.
 * @param effectValue Effect point value.If the amount is in RMB, it is divided into units of measurement.
 */
-(void)reportEffectPoint:(NSString *_Nonnull)effectID effectValue:(long)effectValue;


/**
 * Channel effect statistics, effect details report.
 *
 * Currently, the SDK adopts the periodic reporting policy, and the interval is controlled by the server.
 * Statistics of user payment consumption, click times, etc.
 *
 * @param effectID Effect point id.
 * @param effectValue Effect point value.If the amount is in RMB, it is divided into units of measurement.
 * @param effectDictionary Effect point detail dicitonary，key and value must be passed in string format.
 */
-(void)reportEffectPoint:(NSString *_Nonnull)effectID effectValue:(long)effectValue effectDictionary:(NSDictionary*_Nonnull)effectDictionary;


/**
 * Share report
 *
 * @param shareCode Share user ID.
 * @param sharePlatform Sharing platform. Based on the created `OPO_SharePlatform` string type.
 * @param completedBlock If the report is successful, code=0. If the flight mode/network is poor, or the connection is abnormal, code=-1 indicates that you can retry. In other cases, no retry is required and is returned in the main thread.
 */
-(void)reportShareParametersWithShareCode:(NSString *_Nonnull)shareCode
                           sharePlatform:(OPO_SharePlatform _Nullable)sharePlatform
                               completed:(void (^_Nullable)(NSInteger code,NSString *_Nullable msg))completedBlock;


/**
 *  Gets opid.
 *  Call after initialization, non-asynchronous, must tests on the phone.
 *  you can call this method in `getInstallParmsCompleted` method.
 *  @return string.
 */
- (NSString *_Nullable)getOpId;

@end

