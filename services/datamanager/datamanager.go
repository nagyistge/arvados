/* Keep Datamanager. Responsible for checking on and reporting on Keep Storage */

package main

import (
	"flag"
	"git.curoverse.com/arvados.git/sdk/go/arvadosclient"
	"git.curoverse.com/arvados.git/sdk/go/logger"
	"git.curoverse.com/arvados.git/sdk/go/util"
	"git.curoverse.com/arvados.git/services/datamanager/collection"
	"git.curoverse.com/arvados.git/services/datamanager/keep"
	"log"
	"os"
	"runtime"
	"time"
)

var (
	logEventType        string
	logFrequencySeconds int
)

func init() {
	flag.StringVar(&logEventType,
		"log-event-type",
		"experimental-data-manager-report",
		"event_type to use in our arvados log entries. Set to empty to turn off logging")
	flag.IntVar(&logFrequencySeconds,
		"log-frequency-seconds",
		20,
		"How frequently we'll write log entries in seconds.")
}

func main() {
	flag.Parse()

	arv, err := arvadosclient.MakeArvadosClient()
	if err != nil {
		log.Fatalf("Error setting up arvados client %s", err.Error())
	}

	if is_admin, err := util.UserIsAdmin(arv); err != nil {
		log.Fatalf("Error querying current arvados user %s", err.Error())
	} else if !is_admin {
		log.Fatalf("Current user is not an admin. Datamanager can only be run by admins.")
	}

	var arvLogger *logger.Logger
	if logEventType != "" {
		arvLogger = logger.NewLogger(logger.LoggerParams{Client: arv,
			EventType:            logEventType,
			MinimumWriteInterval: time.Second * time.Duration(logFrequencySeconds)})
	}

	if arvLogger != nil {
		arvLogger.Update(func(p map[string]interface{}, e map[string]interface{}) {
			runInfo := make(map[string]interface{})
			runInfo["start_time"] = time.Now()
			runInfo["args"] = os.Args
			hostname, err := os.Hostname()
			if err != nil {
				runInfo["hostname_error"] = err.Error()
			} else {
				runInfo["hostname"] = hostname
			}
			runInfo["pid"] = os.Getpid()
			p["run_info"] = runInfo
		})

		arvLogger.AddWriteHook(LogMemoryAlloc)
	}

	collectionChannel := make(chan collection.ReadCollections)

	go func() {
		collectionChannel <- collection.GetCollectionsAndSummarize(
			collection.GetCollectionsParams{
				Client: arv, Logger: arvLogger, BatchSize: 50})
	}()

	keepServerInfo := keep.GetKeepServersAndSummarize(
		keep.GetKeepServersParams{Client: arv, Logger: arvLogger, Limit: 1000})

	readCollections := <-collectionChannel

	// TODO(misha): Use these together to verify replication.
	_ = readCollections
	_ = keepServerInfo

	// Log that we're finished. We force the recording, since go will
	// not wait for the timer before exiting.
	if arvLogger != nil {
		arvLogger.ForceUpdate(func(p map[string]interface{}, e map[string]interface{}) {
			p["run_info"].(map[string]interface{})["end_time"] = time.Now()
		})
	}
}

// TODO(misha): Consider moving this to loggerutil
func LogMemoryAlloc(properties map[string]interface{}, entry map[string]interface{}) {
	runInfo := properties["run_info"].(map[string]interface{})
	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)
	runInfo["alloc_bytes_in_use"] = memStats.Alloc
}
