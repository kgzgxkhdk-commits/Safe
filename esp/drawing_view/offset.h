#pragma once

#define kGameFacadeTypeInfo      0xBB46A50 // GameFacade_TypeInfo; OB55 dump/user-provided RVA

// ─── Player / match / camera offsets ─────────────────────────────────────
#define kTypeInfoStatics         0xB8    // GameFacade.TypeInfo: static fields pointer
#define kCurrentGame             0x0     // GameFacade static: current game
#define kCurrentMatchGame        0x8     // GameFacade static: current match game
#define kMatch                   0x90    // MatchGame: Match
#define kMatchLocalPlayer        0xD8    // Match: local Player
#define kCameraControllerManager 0xD8    // MatchGame: CameraControllerManager
#define kMainCamera              0x20    // CameraControllerManager: main Camera
#define kCameraInner             0x10    // Camera: internal camera data
#define kViewMatrixOff           0x80    // Camera data: view matrix
#define kProjMatrixOff           0xC0    // Camera data: projection matrix
#define kBodyPartTransNode       0x10    // BodyPart: ITransformNode
#define kHeadNode                0x6A0   // OB55 Player: head counterpart of OB54 0x638; exact node block mapping
#define kHipNode                 0x6A8   // OB55 Player: hip counterpart of OB54 0x640; exact node block mapping
#define kLeftAnkleNode           0x6D8   // OB55 Player: left ankle counterpart of OB54 0x670
#define kRightAnkleNode          0x6E0   // OB55 Player: right ankle counterpart of OB54 0x678
#define kRightToeNode            0x6F0   // OB55 Player: right toe counterpart of OB54 0x688
#define kLeftToeNode             0x6E8   // OB55 Player: left toe counterpart of OB54 0x680
#define kLeftShoulderNode        0x6C0   // OB55 Player: left shoulder counterpart of OB54 0x658
#define kRightShoulderNode       0x6C8   // OB55 Player: right shoulder counterpart of OB54 0x660
#define kLeftHandNode            0x720   // OB55 Player: left hand counterpart of OB54 0x6B8
#define kRightHandNode           0x718   // OB55 Player: right hand counterpart of OB54 0x6B0
#define kLeftElbowNode           0x730   // OB55 Player: left elbow counterpart of OB54 0x6C8
#define kRightElbowNode          0x728   // OB55 Player: right elbow counterpart of OB54 0x6C0
#define kPlayerIDStruct          0x338   // OB55 Player: shifted PlayerID struct area, OB54 0x2D0 + 0x68
#define kPlayerID                0x408   // OB55 Player: PlayerID field block counterpart to OB54 0x3A0
#define kPlayerIDAlt             0x440   // OB55 Player: generated PlayerID property block
#define kUserID                 0x408   // OB55 Player: user ID alias
#define kIsClientBot             0x4A0   // OB55 Player: IsClientBot counterpart of OB54 0x438
#define kDataPool               0x70    // Player: data pool
#define kDataPoolInner          0x10    // DataPool: inner object
#define kDataPoolEntriesBase    0x20    // DataPool: entries base
#define kDataPoolEntryStride    0x8     // DataPool: entry stride
#define kDataPoolValue          0x18    // DataPool entry: value
#define kAimRotation            0x614   // OB55 Player: Quaternion backing field at Player+0x614
#define kAimRotationAux         0x628   // OB55 Player: Quaternion backing field at Player+0x628
#define kIsFiring               0x259   // OB55 Player: UGCStartFiring bool; bedc6e8 working field
#define _0x27276BC              0x770   // Player: AvatarManager m_AvatarManager
#define _0x28726BD              0x138   // AvatarManager: IUmaAvatar m_Avatar
#define _0x2872DCF              0x101   // IUmaAvatar data: IsVisible
#define kMainCameraTransform    0x3E8   // OB55 Player: MainCameraTransform exact field at 0x3E8
#define kMyPhysXData            0x1B80   // OB55 Player: PhysicalCCT/physx data; bedc6e8 working field
#define kPhxNpeononogeo         0x20    // PhysX data: geometry object
#define kGhgState               0x10    // Geometry object: pose state
#define kKnocked                 0x1150  // OB55 Player: legacy knockdown state object; no renamed field in dump
#define kKnockedDownBleeding     0x1258  // OB55 Player: IsKnockedDownBleed exact field
#define kKnockedDownBleedingGS   0x1259  // OB55 Player: IsKnockDownBleedingFromGS exact field
#define kIsFrozenKnockDown      0x0B0   // OB55 Player: IsFrozenKnockDown exact field from Player class
#define kAliveStateDataId        2       // OB55 EPlayerAliveState: KnockDown entry in DataPool
#define kMatchPlayerDict        0x148   // Match: player dictionary
#define kDictEntries            0x18    // Dictionary: entries array
#define kDictCount              0x20    // Dictionary: count
#define kIl2CppArrayMaxLength   0x18    // Il2CppArray: max length
#define kIl2CppArrayItems       0x20    // Il2CppArray: first item
#define kDictEntryStrideBytePlayer 24   // Dictionary player entry stride
#define kDictEntryValueOffByte 16      // Dictionary player entry: value
#define kTransformInner         0x10    // Transform object: inner
#define kTransformMatrix        0x38    // Transform inner: matrix
#define kTransformIndex         0x40    // Transform inner: matrix index
#define kMatrixList             0x18    // Transform matrix: list
#define kMatrixIndices          0x20    // Transform matrix: indices
#define kNickname               0x498   // OB55 Player: OriginalNickName/name field block counterpart of OB54 0x430
#define kStringFirstChar        0x14    // Il2CppString: first character

// ─── Weapon / PlayerAttributes ─────────────────────────────────────────────
#define _0x5BC2862              0x740   // OB55 Player: inventory manager field
#define _0x2862BCD              0xA0    // InventoryManager: itemOnHand / CHAFOMFBKEG
#define kWeaponCostAmmo         0x7B8   // Legacy weapon field; not verified in OB55
#define kPlayerAttributes       0x768   // Player: PlayerAttributes
#define kFollowCamera           0x690   // OB55 Player: FollowCamera exact field at 0x690
#define kFOVOffset              0x84    // OB55 FollowCamera: public FOVOffset field
#define kPhysCCT                0x268   // Player: PhysicalCCT pointer
#define kPhysCCT_Velocity       0x17C   // PhysicalCCT: velocity
#define kChestNode              0x6B0   // OB55 Player: chest ITransformNode; OB54 counterpart 0x648
#define kNeckNode               0x6A8   // OB55 Player: neck counterpart of OB54 node 0x640
#define kSAim1                  0x7D8   // Player: IsPrepareAttack
#define kLockAimCollider        0x140   // Player: LockAimCollider backing
#define kAimCollider_Ptr        0x6C8   // Player: AimCollider pointer
#define kFollowCamera_Ptr       0x690   // OB55 Player: FollowCamera exact field at 0x690
#define kIsFire_Backing         0x7D0   // Player: IsFire backing
#define kLastAimInfo_Alt        0xE58   // OB55 Player: auxiliary CGKJLKPMGDJ aiming-info field; bedc6e8 working field
#define kLastAimInfoOffset      0xE50   // OB55 Player: CGKJLKPMGDJ aiming-info field; bedc6e8 working field
#define kIsVisible_Uma          0x100   // UMA data: IsVisible
#define kUmaData                0x28    // OB55 UMAAvatarBase: UMAData exact field at 0x28
#define kHit_RayDirectionOffset 0x40    // HitInfo: direction
#define kHit_StartPositionOffset 0x4C   // HitInfo: startPosition
#define kHit_Scatter             0x5C   // HitInfo/GMPGMPFNMFP: scatter
#define kSilentBodyPartTransformOffset kBodyPartTransNode // Player body-part: ITransformNode at BodyPart+0x10
#define kSilentHeadNodeOffset         kHeadNode          // OB55 Player: head ITransformNode at 0x6A0
#define kHitStartPositionOffset       kHit_StartPositionOffset // HitInfo: startPosition at 0x4C
#define kHitRayDirectionOffset        kHit_RayDirectionOffset  // HitInfo: ray direction at 0x40

// ─── Raw external UMA skeleton ─────────────────────────────────────────────
#define kUmaAvatarManagerOffset 0x770  // OB55 Player: AvatarManager exact field at Player+0x770
#define kUmaAvatarOffset        0x138  // AvatarManager: IUmaAvatar m_Avatar
#define kUmaDataOffsetAvatarBase 0x28   // OB55 UMAAvatarBase: public UMAData umaData exact field at 0x28
#define kUmaDataOffsetPrimary   0x28   // IUmaAvatar concrete fallback: UMAData reference candidate
#define kUmaDataOffsetFallback 0x28   // IUmaAvatar concrete fallback: UMAData reference candidate
#define kUmaSkeletonOffset      0x138  // UMAData: UMASkeleton skeleton
#define kUmaBoneListOffset      0x20   // UMASkeleton: boneHashDataBackup
#define kUmaBoneDictionaryOffset 0x28  // UMASkeleton: boneHashDataLookup
#define kUmaListItemsOffset     0x10   // Unity List<T>: _items
#define kUmaListSizeOffset      0x18   // Unity List<T>: _size
#define kUmaArrayItemsOffset    0x20   // Il2CppArray: first element
#define kUmaBoneNameHashOffset  0x10   // BoneData: boneNameHash
#define kUmaBoneTransformOffset 0x18   // BoneData: boneTransform
#define kUmaDictionaryEntriesOffset 0x18 // Dictionary: entries
#define kUmaDictionaryCountOffset 0x20 // Dictionary: count
#define kUmaDictionaryEntryStride 0x18 // Dictionary.Entry<int,BoneData>
#define kUmaDictionaryEntryValueOffset 0x10 // Dictionary.Entry.value
#define kUmaBoneHeadHash          (-2111735698) // BaseBoneMale_Mesh asset: bone_Head
#define kUmaBoneNeckHash          (96688289)    // BaseBoneMale_Mesh asset: bone_Neck
#define kUmaBoneHipsHash          (1529948125)  // BaseBoneMale_Mesh asset: bone_Hips
#define kUmaBoneSpineHash         (-1051086991) // BaseBoneMale_Mesh asset: bone_Spine
#define kUmaBoneSpine1Hash        (-1541408846) // BaseBoneMale_Mesh asset: bone_Spine1
#define kUmaBoneLeftClavHash      (-617253997)  // BaseBoneMale_Mesh asset: bone_LeftClav
#define kUmaBoneRightClavHash     (92030410)    // BaseBoneMale_Mesh asset: bone_RightClav
#define kUmaBoneLeftArmHash       (1604555488)  // BaseBoneMale_Mesh asset: bone_LeftArm
#define kUmaBoneLeftForeArmHash   (-1129867206) // BaseBoneMale_Mesh asset: bone_LeftForeArm
#define kUmaBoneLeftHandHash      (1892485702)  // BaseBoneMale_Mesh asset: bone_LeftHand
#define kUmaBoneRightArmHash      (-1391784435) // BaseBoneMale_Mesh asset: bone_RightArm
#define kUmaBoneRightForeArmHash  (1507255706)  // BaseBoneMale_Mesh asset: bone_RightForeArm
#define kUmaBoneRightHandHash     (-1367065569) // BaseBoneMale_Mesh asset: bone_RightHand
#define kUmaBoneLeftLegUpperHash  (-285661123)  // BaseBoneMale_Mesh asset: bone_LeftLegUpper
#define kUmaBoneLeftLegHash       (-1305646021) // BaseBoneMale_Mesh asset: bone_LeftLeg
#define kUmaBoneLeftAnkleHash     (-344692431)  // BaseBoneMale_Mesh asset: bone_LeftAnkle
#define kUmaBoneLeftToeHash       (-1258743979) // BaseBoneMale_Mesh asset: bone_LeftToe
#define kUmaBoneRightLegUpperHash (952826536)   // BaseBoneMale_Mesh asset: bone_RightLegUpper
#define kUmaBoneRightLegHash      (1082519766)  // BaseBoneMale_Mesh asset: bone_RightLeg
#define kUmaBoneRightAnkleHash    (-115488425)  // BaseBoneMale_Mesh asset: bone_RightAnkle
#define kUmaBoneRightToeHash      (1179749304)  // BaseBoneMale_Mesh asset: bone_RightToe

// ─── Runtime tuning / external scan values ─────────────────────────────────
#define kMagRootNodeOffset       0x6C8  // OB55 Player: ITransformNode counterpart of OB54 root 0x660
#define kMagBodyPartOffset       0x10   // ITransformNode: body-part Transform
#define kMagInnerOffset          0x10   // Transform wrapper: internal transform
#define kMagMatrixOffset         0x38   // Transform object: matrix pointer
#define kMagPositionOffset       0x90   // Transform matrix: world position
#define kMagMaxDisplacementValue 5.00f  // Magnet: hard displacement cap
#define kMagVerticalLiftValue    0.35f  // Magnet: upward-only collider alignment
#define kMagTickMilliseconds     4      // Magnet worker cadence
#define kMagReleaseMilliseconds  200    // Magnet release delay
#define kColliderManagedOffset       0xB30 // OB55 Player: CapsuleCollider field at Player+0xB30
#define kColliderNativePointerOffset 0x10 // Component: native pointer
#define kColliderRadiusOffset        0x80 // Native CapsuleCollider: radius
#define kColliderHeightOffset        0x84 // Native CapsuleCollider: height
#define kColliderBoostRadiusValue     7.00f // Magnet collider tuning
#define kColliderBoostHeightValue    14.00f // Magnet collider tuning
