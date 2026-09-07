package handlers

import (
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/fengtianyu/memorystore/server/internal/auth"
	"github.com/fengtianyu/memorystore/server/internal/device"
	"github.com/fengtianyu/memorystore/server/internal/httpapi/respond"
	"github.com/fengtianyu/memorystore/server/internal/httpapi/middleware"
	"github.com/fengtianyu/memorystore/server/internal/media"
	"github.com/fengtianyu/memorystore/server/internal/share"
	"github.com/fengtianyu/memorystore/server/internal/system"
	"github.com/fengtianyu/memorystore/server/internal/upload"
	"github.com/fengtianyu/memorystore/server/pkg/apperr"
	"github.com/gin-gonic/gin"
)

type Deps struct {
	Auth   *auth.Service
	Device *device.Service
	Upload *upload.Service
	Media  *media.Service
	Share  *share.Service
	System *system.Service
}

func (d *Deps) Register(c *gin.Context) {
	var req struct {
		Username    string `json:"username"`
		Password    string `json:"password"`
		DisplayName string `json:"display_name"`
		InviteCode  string `json:"invite_code"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		respond.Fail(c, apperr.New(apperr.BadRequest, "invalid body"))
		return
	}
	if err := d.Auth.Register(c.Request.Context(), req.Username, req.Password, req.DisplayName, req.InviteCode); err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, gin.H{"registered": true})
}

func (d *Deps) Login(c *gin.Context) {
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		respond.Fail(c, apperr.New(apperr.BadRequest, "invalid body"))
		return
	}
	res, err := d.Auth.Login(c.Request.Context(), req.Username, req.Password, c.Request.UserAgent())
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, res)
}

func (d *Deps) Refresh(c *gin.Context) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		respond.Fail(c, apperr.New(apperr.BadRequest, "invalid body"))
		return
	}
	res, err := d.Auth.Refresh(c.Request.Context(), req.RefreshToken)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, res)
}

func (d *Deps) Logout(c *gin.Context) {
	u := middleware.User(c)
	if err := d.Auth.Logout(c.Request.Context(), u.SessionID); err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, gin.H{"logged_out": true})
}

func (d *Deps) Me(c *gin.Context) {
	u := middleware.User(c)
	me, err := d.Auth.Me(c.Request.Context(), u.UserID)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, me)
}

func (d *Deps) RegisterDevice(c *gin.Context) {
	u := middleware.User(c)
	var in device.RegisterInput
	if err := c.ShouldBindJSON(&in); err != nil {
		respond.Fail(c, apperr.New(apperr.BadRequest, "invalid body"))
		return
	}
	dev, err := d.Device.Register(c.Request.Context(), u.UserID, in)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, gin.H{"device_id": dev.ID, "name": dev.Name, "platform": dev.Platform})
}

func (d *Deps) ListDevices(c *gin.Context) {
	u := middleware.User(c)
	list, err := d.Device.List(c.Request.Context(), u.UserID)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, list)
}

func (d *Deps) RevokeDevice(c *gin.Context) {
	u := middleware.User(c)
	if err := d.Device.Revoke(c.Request.Context(), u.UserID, c.Param("id")); err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, gin.H{"revoked": true})
}

func (d *Deps) MediaCheck(c *gin.Context) {
	u := middleware.User(c)
	var req struct {
		Hashes []string `json:"hashes"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		respond.Fail(c, apperr.New(apperr.BadRequest, "invalid body"))
		return
	}
	res, err := d.Upload.Check(c.Request.Context(), u.UserID, req.Hashes)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, res)
}

func (d *Deps) UploadInit(c *gin.Context) {
	u := middleware.User(c)
	var in upload.InitInput
	if err := c.ShouldBindJSON(&in); err != nil {
		respond.Fail(c, apperr.New(apperr.BadRequest, "invalid body"))
		return
	}
	in.DeviceID = c.GetHeader("X-Device-Id")
	res, err := d.Upload.Init(c.Request.Context(), u.UserID, in)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, res)
}

func (d *Deps) UploadStatus(c *gin.Context) {
	u := middleware.User(c)
	sess, err := d.Upload.Status(c.Request.Context(), u.UserID, c.Param("uploadId"))
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, gin.H{
		"upload_id": sess.ID, "received_bytes": sess.ReceivedBytes, "size_bytes": sess.SizeBytes, "status": sess.Status,
	})
}

func (d *Deps) UploadChunk(c *gin.Context) {
	u := middleware.User(c)
	uploadID := c.Param("uploadId")
	offset, err := parseChunkOffset(c)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	data, err := io.ReadAll(c.Request.Body)
	if err != nil {
		respond.Fail(c, apperr.New(apperr.BadRequest, "read body failed"))
		return
	}
	received, err := d.Upload.WriteChunk(c.Request.Context(), u.UserID, uploadID, offset, data)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, gin.H{"received_bytes": received})
}

func parseChunkOffset(c *gin.Context) (int64, error) {
	if v := c.GetHeader("X-Chunk-Offset"); v != "" {
		return strconv.ParseInt(v, 10, 64)
	}
	cr := c.GetHeader("Content-Range")
	if strings.HasPrefix(cr, "bytes ") {
		var start, end, total int64
		if _, err := fmt.Sscanf(cr, "bytes %d-%d/%d", &start, &end, &total); err == nil {
			return start, nil
		}
	}
	return 0, apperr.New(apperr.BadRequest, "X-Chunk-Offset required")
}

func (d *Deps) UploadComplete(c *gin.Context) {
	u := middleware.User(c)
	res, err := d.Upload.Complete(c.Request.Context(), u.UserID, c.Param("uploadId"))
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, res)
}

func (d *Deps) UploadAbort(c *gin.Context) {
	u := middleware.User(c)
	if err := d.Upload.Abort(c.Request.Context(), u.UserID, c.Param("uploadId")); err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, gin.H{"aborted": true})
}

func (d *Deps) ListMedia(c *gin.Context) {
	u := middleware.User(c)
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "100"))
	var from, to *time.Time
	if v := c.Query("from"); v != "" {
		if t, err := time.Parse(time.RFC3339, v); err == nil {
			from = &t
		}
	}
	if v := c.Query("to"); v != "" {
		if t, err := time.Parse(time.RFC3339, v); err == nil {
			to = &t
		}
	}
	items, cursor, err := d.Media.List(c.Request.Context(), u.UserID, c.Query("cursor"), limit, from, to)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, gin.H{"items": items, "next_cursor": cursor})
}

func (d *Deps) Manifest(c *gin.Context) {
	u := middleware.User(c)
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "100"))
	items, cursor, err := d.Media.Manifest(c.Request.Context(), u.UserID, c.Query("cursor"), limit)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, gin.H{"items": items, "next_cursor": cursor})
}

func (d *Deps) GetMedia(c *gin.Context) {
	u := middleware.User(c)
	item, kinds, err := d.Media.Get(c.Request.Context(), u.UserID, c.Param("id"))
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, gin.H{"media": item, "derivatives": kinds})
}

func (d *Deps) DeleteMedia(c *gin.Context) {
	u := middleware.User(c)
	if err := d.Media.DeleteOne(c.Request.Context(), u.UserID, c.Param("id")); err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, gin.H{"deleted": true})
}

func (d *Deps) PatchMedia(c *gin.Context) {
	u := middleware.User(c)
	var in media.CaptionPatch
	if err := c.ShouldBindJSON(&in); err != nil {
		respond.Fail(c, apperr.New(apperr.BadRequest, "invalid body"))
		return
	}
	item, err := d.Media.PatchCaption(c.Request.Context(), u.UserID, c.Param("id"), in)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, item)
}

func (d *Deps) GenerateMediaStory(c *gin.Context) {
	u := middleware.User(c)
	res, err := d.Media.GenerateStoryDraft(c.Request.Context(), u.UserID, c.Param("id"))
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, res)
}

func (d *Deps) DeleteMediaBatch(c *gin.Context) {
	u := middleware.User(c)
	var in struct {
		MediaIDs []string `json:"media_ids"`
	}
	if err := c.ShouldBindJSON(&in); err != nil {
		respond.Fail(c, apperr.New(apperr.BadRequest, "invalid body"))
		return
	}
	res, err := d.Media.DeleteMany(c.Request.Context(), u.UserID, in.MediaIDs)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, res)
}

func (d *Deps) GetOriginal(c *gin.Context) {
	u := middleware.User(c)
	path, mime, err := d.Media.OriginalPath(c.Request.Context(), u.UserID, c.Param("id"))
	if err != nil {
		respond.Fail(c, err)
		return
	}
	c.Header("Content-Type", mime)
	http.ServeFile(c.Writer, c.Request, path)
}

func (d *Deps) GetDerivative(c *gin.Context) {
	u := middleware.User(c)
	path, err := d.Media.DerivativePath(c.Request.Context(), u.UserID, c.Param("id"), c.Param("kind"))
	if err != nil {
		respond.Fail(c, err)
		return
	}
	c.Header("Content-Type", "image/jpeg")
	http.ServeFile(c.Writer, c.Request, path)
}

func (d *Deps) CreateShare(c *gin.Context) {
	u := middleware.User(c)
	var in share.CreateInput
	if err := c.ShouldBindJSON(&in); err != nil {
		respond.Fail(c, apperr.New(apperr.BadRequest, "invalid body"))
		return
	}
	res, err := d.Share.Create(c.Request.Context(), u.UserID, in)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, res)
}

func (d *Deps) ListShares(c *gin.Context) {
	u := middleware.User(c)
	list, err := d.Share.List(c.Request.Context(), u.UserID)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, list)
}

func (d *Deps) RevokeShare(c *gin.Context) {
	u := middleware.User(c)
	if err := d.Share.Revoke(c.Request.Context(), u.UserID, c.Param("id")); err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, gin.H{"revoked": true})
}

func (d *Deps) PublicShareMeta(c *gin.Context) {
	token := c.GetHeader("X-Share-Token")
	rs, err := d.Share.ResolveToken(c.Request.Context(), token, c.GetHeader("X-Share-Password"))
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, gin.H{
		"title": rs.Link.Title, "expires_at": rs.Link.ExpiresAt,
		"password_required": rs.Link.PasswordHash != "", "media_count": len(rs.MediaIDs),
	})
}

func (d *Deps) PublicShareMedia(c *gin.Context) {
	token := c.GetHeader("X-Share-Token")
	rs, err := d.Share.ResolveToken(c.Request.Context(), token, c.GetHeader("X-Share-Password"))
	if err != nil {
		respond.Fail(c, err)
		return
	}
	items := make([]gin.H, 0, len(rs.MediaIDs))
	for _, id := range rs.MediaIDs {
		m, kinds, err := d.Media.Get(c.Request.Context(), rs.Link.UserID, id)
		if err != nil {
			continue
		}
		items = append(items, gin.H{"media": m, "derivatives": kinds})
	}
	respond.OK(c, gin.H{"items": items})
}

func (d *Deps) PublicShareFile(c *gin.Context) {
	token := c.GetHeader("X-Share-Token")
	rs, err := d.Share.ResolveToken(c.Request.Context(), token, c.GetHeader("X-Share-Password"))
	if err != nil {
		respond.Fail(c, err)
		return
	}
	id := c.Param("id")
	if !d.Share.Allows(rs, id) {
		respond.Fail(c, apperr.New(apperr.NotFound, "not found"))
		return
	}
	path, mime, _, err := d.Media.ResolveOriginalByID(c.Request.Context(), id)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	c.Header("Content-Type", mime)
	http.ServeFile(c.Writer, c.Request, path)
}

func (d *Deps) PublicShareDerivative(c *gin.Context) {
	token := c.GetHeader("X-Share-Token")
	rs, err := d.Share.ResolveToken(c.Request.Context(), token, c.GetHeader("X-Share-Password"))
	if err != nil {
		respond.Fail(c, err)
		return
	}
	id := c.Param("id")
	if !d.Share.Allows(rs, id) {
		respond.Fail(c, apperr.New(apperr.NotFound, "not found"))
		return
	}
	path, err := d.Media.ResolveDerivativeByID(c.Request.Context(), id, c.Param("kind"))
	if err != nil {
		respond.Fail(c, err)
		return
	}
	c.Header("Content-Type", "image/jpeg")
	http.ServeFile(c.Writer, c.Request, path)
}

func (d *Deps) Health(c *gin.Context) {
	h := d.System.Health(c.Request.Context())
	code := http.StatusOK
	if !h.OK {
		code = http.StatusServiceUnavailable
	}
	c.JSON(code, h)
}

func (d *Deps) Storage(c *gin.Context) {
	u := middleware.User(c)
	info, err := d.System.StorageInfo(c.Request.Context(), u.UserID)
	if err != nil {
		respond.Fail(c, err)
		return
	}
	respond.OK(c, info)
}
