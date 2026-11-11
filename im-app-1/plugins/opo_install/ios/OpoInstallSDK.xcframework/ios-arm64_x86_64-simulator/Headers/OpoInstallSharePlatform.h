
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Share platform identifiers for `-[OpoInstallSDK reportShareParametersWithShareCode:sharePlatform:completed:]`.
 */
typedef NSString *OPO_SharePlatform NS_STRING_ENUM;

#pragma mark - WeChat

/** 微信好友 WechatSession */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_WechatSession;
/** 微信朋友圈 WechatTimeline */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_WechatTimeline;
/** 微信收藏 WechatFavorite */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_WechatFavorite;
/** 企业微信 WeCom（原名 WechatWork） */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_WeCom;

#pragma mark - Tencent

/** QQ 好友 */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_QQ;
/** QQ 空间 */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Qzone;
/** 腾讯 Tim */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_TencentTim;
/** 腾讯微博 TencentWb */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_TencentWb;

#pragma mark - Domestic

/** 新浪微博 Sina */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Sina;
/** 支付宝好友 */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_APSession;
/** 钉钉 */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_DingDing;
/** 抖音国内版 */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_DouYin;
/** 快手 */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Kuaishou;
/** 西瓜视频 */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_WatermelonVideo;
/** 人人网 Renren */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Renren;
/** 豆瓣 Douban */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Douban;
/** 明道 MingDao */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_MingDao;

#pragma mark - International short video

/** 抖音海外版 TikTok */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_TikTok;
/** 快手国际版 Kwai */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Kwai;
/** 西瓜视频国际版 BuzzVideo */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_BuzzVideo;

#pragma mark - System share

/** 邮箱 Email */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Email;
/** 短信 Sms */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Sms;
/** 复制 Copy */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Copy;

#pragma mark - Facebook

FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Facebook;
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_FacebookMessenger;
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_FacebookAccount;

#pragma mark - Global social

/** 推特 Twitter */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Twitter;
/** Instagram */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Instagram;
/** Whatsapp */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Whatsapp;
/** Youtube */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Youtube;
/** SnapChat */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_SnapChat;
/** Line */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Line;
/** Linkedin */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Linkedin;
/** Reddit */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Reddit;
/** Tumblr */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Tumblr;
/** Pinterest */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Pinterest;
/** Kakao Talk */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_KakaoTalk;
/** Kakao Story */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_KakaoStory;
/** Flickr */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Flickr;
/** Google+ */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_googlePlus;
/** vkontakte */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_vkontakte;
/** Oasis */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Oasis;
/** Apple 账户 */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_AppleAccount;

#pragma mark - Legacy domestic

/** 易信好友 YXSession */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_YXSession;
/** 易信朋友圈 YXTimeline */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_YXTimeline;
/** 易信收藏夹 YXFavorite */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_YXFavorite;
/** 来往好友 LWSession */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_LWSession;
/** 来往朋友圈 LWTimeline */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_LWTimeline;

#pragma mark - Notes & cloud

/** 有道云笔记 YouDaoNote */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_YouDaoNote;
/** 印象笔记 YinxiangNote */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_YinxiangNote;
/** 印象笔记国际版 EverNote */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_EverNote;
/** Pocket */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Pocket;
/** Dropbox */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_dropbox;
/** Instapaper */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Instapaper;

#pragma mark - Other

/** 其它平台 Other */
FOUNDATION_EXPORT OPO_SharePlatform const OPO_SharePlatform_Other;

NS_ASSUME_NONNULL_END
