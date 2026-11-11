
#import <Foundation/Foundation.h>

// Share platform constants were moved to OpoInstallSharePlatform.h; re-exported here for compatibility.
#import "OpoInstallSharePlatform.h"

//NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, OPO_Codes) {
    /** Initialization complete; parameters returned (empty for organic installs). */
    OPOCode_normal = 0,
    /** Parameter fetch timed out; retry later if needed. */
    OPOCode_timeout = 1,
};

/**
 * Install attribution data returned by install parameter APIs.
 */
@interface OpoInstallData : NSObject <NSCopying>

- (instancetype)initWithData:(NSDictionary *)data
                 channelCode:(NSString *)channelCode;

/** Dynamic parameter dictionary. */
@property (nonatomic, strong) NSDictionary *data;
/** Channel number. */
@property (nonatomic, copy) NSString *channelCode;
/** Result code; use to detect install parameter timeout. */
@property (nonatomic, assign) OPO_Codes opCode;

@end

//NS_ASSUME_NONNULL_END
