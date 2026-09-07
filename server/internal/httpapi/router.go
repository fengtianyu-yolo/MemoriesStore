package httpapi

import (
	"github.com/fengtianyu/memorystore/server/internal/httpapi/handlers"
	"github.com/fengtianyu/memorystore/server/internal/httpapi/middleware"
	"github.com/gin-gonic/gin"
)

func NewRouter(d *handlers.Deps) *gin.Engine {
	r := gin.New()
	r.Use(gin.Recovery(), gin.Logger())

	r.GET("/health", d.Health)

	v1 := r.Group("/api/v1")
	{
		v1.POST("/auth/register", d.Register)
		v1.POST("/auth/login", d.Login)
		v1.POST("/auth/refresh", d.Refresh)

		authz := v1.Group("")
		authz.Use(middleware.RequireUser(d.Auth))
		{
			authz.POST("/auth/logout", d.Logout)
			authz.GET("/me", d.Me)

			authz.POST("/devices/register", d.RegisterDevice)
			authz.GET("/devices", d.ListDevices)
			authz.DELETE("/devices/:id", d.RevokeDevice)

			authz.POST("/media/check", d.MediaCheck)
			authz.POST("/upload/init", d.UploadInit)
			authz.GET("/upload/:uploadId/status", d.UploadStatus)
			authz.PUT("/upload/:uploadId/chunk", d.UploadChunk)
			authz.POST("/upload/:uploadId/complete", d.UploadComplete)
			authz.POST("/upload/:uploadId/abort", d.UploadAbort)

			authz.GET("/sync/manifest", d.Manifest)
			authz.GET("/media", d.ListMedia)
			authz.POST("/media/delete", d.DeleteMediaBatch)
			authz.GET("/media/:id", d.GetMedia)
			authz.PATCH("/media/:id", d.PatchMedia)
			authz.POST("/media/:id/story/ai", d.GenerateMediaStory)
			authz.DELETE("/media/:id", d.DeleteMedia)
			authz.GET("/media/:id/original", d.GetOriginal)
			authz.GET("/media/:id/derivatives/:kind", d.GetDerivative)

			authz.POST("/shares", d.CreateShare)
			authz.GET("/shares", d.ListShares)
			authz.DELETE("/shares/:id", d.RevokeShare)

			authz.GET("/system/storage", d.Storage)
		}

		pub := v1.Group("/public/share")
		{
			pub.GET("/meta", d.PublicShareMeta)
			pub.GET("/media", d.PublicShareMedia)
			pub.GET("/media/:id/file", d.PublicShareFile)
			pub.GET("/media/:id/derivatives/:kind", d.PublicShareDerivative)
		}
	}

	r.Static("/assets", "./web/dist/assets")
	r.NoRoute(func(c *gin.Context) {
		path := c.Request.URL.Path
		if len(path) >= 4 && path[:4] == "/api" {
			c.JSON(404, gin.H{"ok": false, "error": gin.H{"code": "NOT_FOUND", "message": "not found"}})
			return
		}
		c.File("./web/dist/index.html")
	})

	return r
}
