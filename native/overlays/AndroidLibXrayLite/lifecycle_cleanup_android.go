//go:build android

package libv2ray

// CleanupLoop releases both running and partially initialized core instances.
//
// Upstream StopLoop returns when IsRunning is false. That leaves coreInstance
// allocated when core.New succeeds but coreInstance.Start fails. Android
// service cleanup must also cover that failed-start state because its TUN
// descriptor has already been established.
func (x *CoreController) CleanupLoop() {
	x.coreMutex.Lock()
	defer x.coreMutex.Unlock()

	x.doShutdown()
	x.CallbackHandler.OnEmitStatus(0, "Core cleaned up")
}
